import io
import os
import urllib.request
from PIL import Image

URL = "https://gallerypng.com/wp-content/uploads/2024/05/amul-logo-image-free-download.png"

os.makedirs("static", exist_ok=True)
req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})

with urllib.request.urlopen(req) as response:
    data = response.read()

# Converts any format (webp, jpg, png) into a real PNG
Image.open(io.BytesIO(data)).convert("RGBA").save("static/amul_logo.png")
print("Saved static/amul_logo.png")