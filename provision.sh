#!/bin/bash
# =============================================================================
# Vast.ai Serverless — ComfyUI Provisioning Script
# This runs on first boot of each worker. Models are downloaded once
# and cached on the worker's disk for subsequent requests.
# =============================================================================

COMFY="/opt/ComfyUI"
MODELS="$COMFY/models"
NODES="$COMFY/custom_nodes"
_R="https://huggingface.co/zakraaa/reed-workflow-models/resolve/main"

echo "=== PROVISIONING START ==="

# ── 1. SYSTEM DEPS ────────────────────────────────────────────────────
apt-get update -qq && apt-get install -y -qq libxcb1 libgl1-mesa-glx libglib2.0-0 2>/dev/null

# ── 2. PYTHON DEPS ────────────────────────────────────────────────────
pip3 install --no-cache-dir \
    opencv-python-headless mediapipe websocket-client \
    segment-anything scikit-image piexif scipy dill matplotlib \
    ultralytics onnxruntime-gpu torchsde sqlalchemy blake3 \
    insightface facexlib 2>/dev/null

# ── 3. DIRECTORIES ────────────────────────────────────────────────────
for dir in checkpoints loras diffusion_models text_encoders vae sams controlnet ipadapter; do
    mkdir -p "$MODELS/$dir"
done
mkdir -p "$MODELS/ultralytics/bbox"

# ── 4. MODELS ─────────────────────────────────────────────────────────
dl() {
    local url="$1" out="$2" name="$3"
    if [ -f "$out" ] && [ $(stat -c%s "$out" 2>/dev/null || echo 0) -gt 100000 ]; then
        echo "SKIP $name"
        return
    fi
    echo "Downloading $name..."
    curl -L --connect-timeout 30 --retry 3 -o "$out" "$url" 2>/dev/null
}

# SDXL Checkpoints
dl "${_R}/bigLust_v16.safetensors" "$MODELS/checkpoints/bigLust_v16.safetensors" "bigLust (6.5GB)"
dl "${_R}/natvisNaturalVision_v27.safetensors" "$MODELS/checkpoints/natvisNaturalVision_v27.safetensors" "natvis (6.5GB)"

# SDXL LoRAs
dl "${_R}/dmd2_sdxl_4step_lora.safetensors" "$MODELS/loras/dmd2_sdxl_4step_lora.safetensors" "dmd2 (750MB)"

# Z-Image Turbo
dl "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" "$MODELS/diffusion_models/z_image_turbo_bf16.safetensors" "ZIT UNET (12GB)"
dl "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" "$MODELS/text_encoders/qwen_3_4b.safetensors" "ZIT CLIP (8GB)"
dl "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" "$MODELS/vae/z-image-turbo-vae.safetensors" "ZIT VAE (335MB)"

# Detection Models
dl "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth" "$MODELS/sams/sam_vit_b_01ec64.pth" "SAM (375MB)"
dl "https://github.com/hben35096/assets/releases/download/yolo8/hair_yolov8n-seg_60.pt" "$MODELS/ultralytics/bbox/hair_yolov8n-seg_60.pt" "YOLO (6MB)"

# IP-Adapter FaceID
dl "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid_sdxl.bin" "$MODELS/ipadapter/ip-adapter-faceid_sdxl.bin" "FaceID SDXL (1GB)"
dl "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid_sdxl_lora.safetensors" "$MODELS/loras/ip-adapter-faceid_sdxl_lora.safetensors" "FaceID LoRA (355MB)"

# CLIP Vision for IP-Adapter
dl "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" "$MODELS/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" "CLIP Vision (2.5GB)"

# ── 5. CUSTOM NODES ───────────────────────────────────────────────────
install_node() {
    local url="$1" dir="$2" name="$3"
    if [ -d "$NODES/$dir" ]; then
        echo "SKIP $name"
        return
    fi
    echo "Installing $name..."
    git clone --depth 1 "$url" "$NODES/$dir" 2>/dev/null
    [ -f "$NODES/$dir/.gitmodules" ] && git -C "$NODES/$dir" submodule update --init --recursive 2>/dev/null
    [ -f "$NODES/$dir/requirements.txt" ] && pip3 install --no-cache-dir -r "$NODES/$dir/requirements.txt" 2>/dev/null
    [ -f "$NODES/$dir/install.py" ] && python3 "$NODES/$dir/install.py" 2>/dev/null
}

install_node "https://github.com/ClownsharkBatwing/RES4LYF" "RES4LYF" "RES4LYF"
install_node "https://github.com/ltdrdata/ComfyUI-Impact-Pack" "ComfyUI-Impact-Pack" "Impact Pack"
install_node "https://github.com/ltdrdata/ComfyUI-Impact-Subpack" "ComfyUI-Impact-Subpack" "Impact Subpack"
install_node "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch" "ComfyUI-Inpaint-CropAndStitch" "Inpaint CropAndStitch"
install_node "https://github.com/Fannovel16/comfyui_controlnet_aux" "comfyui_controlnet_aux" "ControlNet Aux"
install_node "https://github.com/sipherxyz/comfyui-art-venture" "comfyui-art-venture" "Art Venture"
install_node "https://github.com/cubiq/ComfyUI_IPAdapter_plus" "ComfyUI_IPAdapter_plus" "IPAdapter Plus"

# Reinstall cv2 + mediapipe AFTER nodes (nodes may override)
pip3 install --no-cache-dir opencv-python-headless mediapipe 2>/dev/null

# ── 6. DISABLE MANAGER ────────────────────────────────────────────────
[ -d "$NODES/ComfyUI-Manager" ] && mv "$NODES/ComfyUI-Manager" "$NODES/ComfyUI-Manager.disabled" 2>/dev/null

echo "=== PROVISIONING DONE ==="
