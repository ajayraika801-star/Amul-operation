// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract AmulSCM {
    uint public constant FEE = 1 ether;

    address public owner;
    address payable public treasury;

    // Stages: 1 Collection, 2 Chilling, 3 Testing, 4 Packing, 5 Distributor, 6 Retail
    struct Record {
        uint id;
        uint8 stage;
        uint parentId;
        bool approved;
        string payload;
        uint timestamp;
        address actor;
    }

    // Appended update: a new entry linked to an existing record
    struct Note {
        uint id;
        uint recordId;
        uint8 stage;
        string text;
        uint timestamp;
        address actor;
    }

    // Return case for a retail delivery.
    // step: 1 Raised, 2 Picked up, 3 Inspected, 4 Closed
    // disposition: 0 pending, 1 Destroy, 2 Reprocess, 3 Restock, 4 Claim rejected
    struct ReturnCase {
        uint id;
        uint recordId;
        uint units;
        uint8 step;
        uint8 disposition;
        uint timestamp;
        address actor;
    }

    // Every step of a return is its own permanent entry
    struct ReturnEvent {
        uint id;
        uint returnId;
        uint8 step;
        string payload;
        uint timestamp;
        address actor;
    }

    mapping(uint => Record) public records;
    mapping(uint => Note) public notes;
    mapping(uint => ReturnCase) public returnCases;
    mapping(uint => ReturnEvent) public returnEvents;
    mapping(uint8 => uint) public stageCount;
    mapping(address => uint8) public stageOf;

    uint public recordCount;
    uint public noteCount;
    uint public returnCount;
    uint public returnEventCount;
    uint public totalCollected;

    event Recorded(uint indexed id, uint8 indexed stage, uint parentId, address indexed actor);
    event Appended(uint indexed noteId, uint indexed recordId, address indexed actor);
    event ReturnLogged(uint indexed returnId, uint indexed eventId, uint8 step);

    constructor() {
        owner = msg.sender;
        treasury = payable(msg.sender);
    }

    function assignStage(address unit, uint8 stage) external {
        require(msg.sender == owner, "Only owner");
        require(stage >= 1 && stage <= 6, "Invalid stage");
        stageOf[unit] = stage;
    }

    // Append-only: there is no update or delete function.
    function addRecord(
        uint8 stage,
        uint parentId,
        bool approved,
        string calldata payload
    ) external payable returns (uint) {
        require(stage >= 1 && stage <= 6, "Invalid stage");
        require(stageOf[msg.sender] == stage, "Unauthorized unit");
        require(msg.value == FEE, "Each transaction needs exactly 1 ETH");

        if (stage == 1) {
            require(parentId == 0, "Stage 1 has no parent");
        } else {
            require(parentId > 0 && parentId <= recordCount, "Parent not found");
            Record storage p = records[parentId];
            require(p.stage == stage - 1, "Wrong parent stage");
            require(p.approved, "Parent batch failed quality test");
        }

        if (stage != 3) {
            require(approved, "Only testing can reject");
        }

        recordCount++;
        stageCount[stage]++;
        totalCollected += msg.value;

        Record storage r = records[recordCount];
        r.id = recordCount;
        r.stage = stage;
        r.parentId = parentId;
        r.approved = approved;
        r.payload = payload;
        r.timestamp = block.timestamp;
        r.actor = msg.sender;

        (bool ok, ) = treasury.call{value: msg.value}("");
        require(ok, "ETH transfer failed");

        emit Recorded(recordCount, stage, parentId, msg.sender);
        return recordCount;
    }

    // Append an update to any existing record. The record itself never changes.
    function appendNote(uint recordId, string calldata text) external payable returns (uint) {
        require(stageOf[msg.sender] != 0, "Unauthorized unit");
        require(recordId > 0 && recordId <= recordCount, "Record not found");
        require(bytes(text).length > 0 && bytes(text).length <= 280, "Note must be 1 to 280 bytes");
        require(msg.value == FEE, "Each transaction needs exactly 1 ETH");

        noteCount++;
        totalCollected += msg.value;

        Note storage n = notes[noteCount];
        n.id = noteCount;
        n.recordId = recordId;
        n.stage = stageOf[msg.sender];
        n.text = text;
        n.timestamp = block.timestamp;
        n.actor = msg.sender;

        (bool ok, ) = treasury.call{value: msg.value}("");
        require(ok, "ETH transfer failed");

        emit Appended(noteCount, recordId, msg.sender);
        return noteCount;
    }

    // ---------------- Returns and damage ----------------

    // Step 1: Retail raises a return against a retail delivery.
    function raiseReturn(uint recordId, uint units, string calldata payload)
        external payable returns (uint)
    {
        require(stageOf[msg.sender] == 6, "Only retail can raise a return");
        require(recordId > 0 && recordId <= recordCount, "Record not found");
        require(records[recordId].stage == 6, "Only retail deliveries can be returned");
        require(units > 0, "Units must be above zero");
        require(msg.value == FEE, "Each transaction needs exactly 1 ETH");

        returnCount++;
        ReturnCase storage c = returnCases[returnCount];
        c.id = returnCount;
        c.recordId = recordId;
        c.units = units;
        c.step = 1;
        c.timestamp = block.timestamp;
        c.actor = msg.sender;

        _logReturn(returnCount, 1, payload);
        _takeFee();
        return returnCount;
    }

    // Steps 2 to 4, in order:
    // 2 Pickup (distributor), 3 Inspection (testing lab), 4 Credit and closure (packing/dairy)
    function advanceReturn(uint returnId, uint8 disposition, string calldata payload)
        external payable returns (uint)
    {
        require(returnId > 0 && returnId <= returnCount, "Return not found");
        require(msg.value == FEE, "Each transaction needs exactly 1 ETH");

        ReturnCase storage c = returnCases[returnId];
        require(c.step < 4, "Return already closed");

        uint8 next = c.step + 1;
        uint8 needed = 4;
        if (next == 2) {
            needed = 5;
        } else if (next == 3) {
            needed = 3;
        }
        require(stageOf[msg.sender] == needed, "Wrong unit for this step");

        if (next == 3) {
            require(disposition >= 1 && disposition <= 4, "Invalid disposition");
            c.disposition = disposition;
        }
        c.step = next;

        uint eventId = _logReturn(returnId, next, payload);
        _takeFee();
        return eventId;
    }

    function _logReturn(uint returnId, uint8 step, string memory payload) internal returns (uint) {
        returnEventCount++;
        ReturnEvent storage e = returnEvents[returnEventCount];
        e.id = returnEventCount;
        e.returnId = returnId;
        e.step = step;
        e.payload = payload;
        e.timestamp = block.timestamp;
        e.actor = msg.sender;
        emit ReturnLogged(returnId, returnEventCount, step);
        return returnEventCount;
    }

    function _takeFee() internal {
        totalCollected += msg.value;
        (bool ok, ) = treasury.call{value: msg.value}("");
        require(ok, "ETH transfer failed");
    }
}