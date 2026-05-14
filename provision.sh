#!/bin/bash
# =============================================================================
# Complete setup for Vast.ai ComfyUI pod
# Paste in Jupyter Lab cell with %%bash at the top
# Shows progress for every step
# =============================================================================

COMFY="/workspace/ComfyUI"
MODELS="$COMFY/models"
NODES="$COMFY/custom_nodes"
_R="https://huggingface.co/zakraaa/reed-workflow-models/resolve/main"
TOTAL_STEPS=6
START=$(date +%s)

step() { echo ""; echo "========================================"; echo "  [$1/$TOTAL_STEPS] $2"; echo "========================================"; }
elapsed() { echo "  ($(( $(date +%s) - START ))s elapsed)"; }

# ── 1. KILL EVERYTHING ──────────────────────────────────────────────────
step 1 "LIMPIANDO"
pkill -9 -f 'python.*main.py' 2>/dev/null
pkill -9 -f gunicorn 2>/dev/null
sleep 3
rm -f "$COMFY/user/comfyui.db" 2>/dev/null
[ -d "$NODES/ComfyUI-Manager" ] && mv "$NODES/ComfyUI-Manager" "$NODES/ComfyUI-Manager.disabled" 2>/dev/null
rm -f "$MODELS/checkpoints/v1-5-pruned-emaonly-fp16.safetensors" 2>/dev/null
rm -f "$MODELS/checkpoints/sd_xl_turbo_1.0_fp16.safetensors" 2>/dev/null
echo "  OK"
elapsed

# ── 2. INSTALL ALL DEPENDENCIES ────────────────────────────────────────
step 2 "DEPENDENCIAS PYTHON"
echo "  Instalando opencv, mediapipe, flask, gunicorn..."
pip3 install --no-cache-dir \
    opencv-python-headless mediapipe flask gunicorn websocket-client \
    segment-anything scikit-image piexif scipy dill matplotlib \
    ultralytics onnxruntime-gpu requests insightface facexlib 2>&1 | grep -E "^(Successfully|ERROR|Requirement)" | tail -3
echo "  Instalando ComfyUI requirements..."
cd "$COMFY" && pip3 install --no-cache-dir -r requirements.txt 2>&1 | grep -E "^(Successfully|ERROR|Requirement)" | tail -1
echo "  Instalando torchsde, sqlalchemy, blake3..."
pip3 install --no-cache-dir torchsde sqlalchemy blake3 2>&1 | grep -E "^(Successfully|ERROR|Requirement)" | tail -1
echo "  OK"
elapsed

# ── 3. DIRECTORIES ──────────────────────────────────────────────────────
for dir in checkpoints loras diffusion_models text_encoders vae sams controlnet onnx ipadapter clip_vision; do
    mkdir -p "$MODELS/$dir"
done
mkdir -p "$MODELS/ultralytics/bbox"

# ── 4. MODELS ───────────────────────────────────────────────────────────
step 3 "MODELOS (~40GB - esto tarda 10-15 min)"

dl() {
    local url="$1" out="$2" name="$3"
    if [ -f "$out" ] && [ $(stat -c%s "$out" 2>/dev/null || echo 0) -gt 100000 ]; then
        echo "  SKIP $name (ya existe)"
        return
    fi
    echo "  Descargando $name..."
    curl -L --connect-timeout 30 --retry 3 --progress-bar -o "$out" "$url"
    local size=$(stat -c%s "$out" 2>/dev/null || echo 0)
    echo "  OK $name ($(( size / 1048576 ))MB)"
}

dl "${_R}/bigLust_v16.safetensors" "$MODELS/checkpoints/bigLust_v16.safetensors" "bigLust (6.5GB)"
dl "${_R}/natvisNaturalVision_v27.safetensors" "$MODELS/checkpoints/natvisNaturalVision_v27.safetensors" "natvis (6.5GB)"
dl "${_R}/dmd2_sdxl_4step_lora.safetensors" "$MODELS/loras/dmd2_sdxl_4step_lora.safetensors" "dmd2 LoRA (750MB)"
dl "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" "$MODELS/diffusion_models/z_image_turbo_bf16.safetensors" "ZIT UNET (12GB)"
dl "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" "$MODELS/text_encoders/qwen_3_4b.safetensors" "ZIT CLIP (8GB)"
dl "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" "$MODELS/vae/z-image-turbo-vae.safetensors" "ZIT VAE (335MB)"
dl "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth" "$MODELS/sams/sam_vit_b_01ec64.pth" "SAM (375MB)"
dl "https://github.com/hben35096/assets/releases/download/yolo8/hair_yolov8n-seg_60.pt" "$MODELS/ultralytics/bbox/hair_yolov8n-seg_60.pt" "YOLO (6MB)"
dl "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid_sdxl.bin" "$MODELS/ipadapter/ip-adapter-faceid_sdxl.bin" "FaceID SDXL (1GB)"
dl "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid_sdxl_lora.safetensors" "$MODELS/loras/ip-adapter-faceid_sdxl_lora.safetensors" "FaceID LoRA (355MB)"
dl "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" "$MODELS/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" "CLIP Vision (2.5GB)"
elapsed

# ── 5. CUSTOM NODES ─────────────────────────────────────────────────────
step 4 "CUSTOM NODES"

install_node() {
    local url="$1" dir="$2" name="$3"
    if [ -d "$NODES/$dir" ]; then
        echo "  SKIP $name (ya existe)"
        return
    fi
    echo "  Instalando $name..."
    git clone --depth 1 "$url" "$NODES/$dir" 2>/dev/null
    [ -f "$NODES/$dir/.gitmodules" ] && git -C "$NODES/$dir" submodule update --init --recursive 2>/dev/null
    [ -f "$NODES/$dir/requirements.txt" ] && pip3 install --no-cache-dir -r "$NODES/$dir/requirements.txt" 2>&1 | tail -1
    [ -f "$NODES/$dir/install.py" ] && python3 "$NODES/$dir/install.py" 2>/dev/null
    echo "  OK $name"
}

install_node "https://github.com/ClownsharkBatwing/RES4LYF" "RES4LYF" "RES4LYF"
install_node "https://github.com/ltdrdata/ComfyUI-Impact-Pack" "ComfyUI-Impact-Pack" "Impact Pack"
install_node "https://github.com/ltdrdata/ComfyUI-Impact-Subpack" "ComfyUI-Impact-Subpack" "Impact Subpack"
install_node "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch" "ComfyUI-Inpaint-CropAndStitch" "Inpaint CropAndStitch"
install_node "https://github.com/Fannovel16/comfyui_controlnet_aux" "comfyui_controlnet_aux" "ControlNet Aux"
install_node "https://github.com/sipherxyz/comfyui-art-venture" "comfyui-art-venture" "Art Venture"
install_node "https://github.com/cubiq/ComfyUI_IPAdapter_plus" "ComfyUI_IPAdapter_plus" "IPAdapter Plus"
install_node "https://github.com/cubiq/PuLID_ComfyUI" "PuLID_ComfyUI" "PuLID"

echo "  Reinstalando cv2 + mediapipe (fix overrides)..."
pip3 install --no-cache-dir opencv-python-headless mediapipe 2>&1 | tail -1
echo "  OK"
elapsed

# ── 6. VERIFICACION ─────────────────────────────────────────────────────
step 5 "VERIFICACION"
FAIL=0
echo "  Modelos:"
for f in checkpoints/bigLust_v16.safetensors checkpoints/natvisNaturalVision_v27.safetensors \
         loras/dmd2_sdxl_4step_lora.safetensors diffusion_models/z_image_turbo_bf16.safetensors \
         text_encoders/qwen_3_4b.safetensors vae/z-image-turbo-vae.safetensors \
         sams/sam_vit_b_01ec64.pth ultralytics/bbox/hair_yolov8n-seg_60.pt \
         ipadapter/ip-adapter-faceid_sdxl.bin; do
    if [ -f "$MODELS/$f" ] && [ $(stat -c%s "$MODELS/$f" 2>/dev/null || echo 0) -gt 100000 ]; then
        echo "    OK $f"
    else
        echo "    FALTA $f"
        FAIL=1
    fi
done
echo "  Custom nodes:"
for d in RES4LYF ComfyUI-Impact-Pack ComfyUI-Impact-Subpack ComfyUI-Inpaint-CropAndStitch comfyui_controlnet_aux comfyui-art-venture ComfyUI_IPAdapter_plus; do
    [ -d "$NODES/$d" ] && echo "    OK $d" || { echo "    FALTA $d"; FAIL=1; }
done
echo "  Python:"
python3 -c "import cv2; print('    OK cv2')" 2>&1
python3 -c "import mediapipe; print('    OK mediapipe')" 2>&1
python3 -c "import flask; print('    OK flask')" 2>&1
echo "  Disco:"
df -h / | tail -1
[ $FAIL -eq 1 ] && echo "  HAY ERRORES - revisa arriba" && exit 1
echo "  TODO OK"
elapsed

# ── 7. START COMFYUI ──────────────────────────────────────────────────
step 6 "ARRANCANDO"
pkill -9 -f 'python.*main.py' 2>/dev/null
sleep 3
rm -f "$COMFY/user/comfyui.db" 2>/dev/null

cd "$COMFY" && python3 main.py --listen 127.0.0.1 --port 18199 > /workspace/comfyui.log 2>&1 &
CPID=$!
echo "  ComfyUI PID: $CPID"
echo "  Esperando ComfyUI (max 120s)..."

for i in $(seq 1 60); do
    sleep 2
    if curl -s --connect-timeout 2 http://127.0.0.1:18199/ > /dev/null 2>&1; then
        echo "  ComfyUI OK (${i}x2s = $((i*2))s)"
        break
    fi
    if ! kill -0 $CPID 2>/dev/null; then
        echo "  ComfyUI CRASHED - log:"
        tail -20 /workspace/comfyui.log
        exit 1
    fi
    [ $((i % 10)) -eq 0 ] && echo "  ...esperando ($((i*2))s)..."
done

# Verify critical node
echo "  Verificando nodos criticos..."
NODE=$(curl -s --connect-timeout 5 http://127.0.0.1:18199/object_info/MediaPipeFaceMeshToSEGS 2>/dev/null)
if [ "$NODE" = "{}" ] || [ -z "$NODE" ]; then
    echo "  MediaPipeFaceMeshToSEGS FALTA - intentando fix..."
    pip3 install --no-cache-dir --force-reinstall opencv-python-headless mediapipe 2>/dev/null
    pkill -9 -f 'python.*main.py' 2>/dev/null
    sleep 3
    rm -f "$COMFY/user/comfyui.db" 2>/dev/null
    cd "$COMFY" && python3 main.py --listen 127.0.0.1 --port 18199 > /workspace/comfyui.log 2>&1 &
    echo "  Reiniciando ComfyUI (esperando 120s)..."
    sleep 120
    NODE2=$(curl -s --connect-timeout 5 http://127.0.0.1:18199/object_info/MediaPipeFaceMeshToSEGS 2>/dev/null)
    [ "$NODE2" = "{}" ] || [ -z "$NODE2" ] && echo "  SIGUE FALTANDO" || echo "  MediaPipeFaceMeshToSEGS OK (2nd try)"
else
    echo "  MediaPipeFaceMeshToSEGS OK"
fi

# ── 8. WRITE + START HANDLER ────────────────────────────────────────────
echo "  Escribiendo handler (svc.py)..."
cat > /workspace/svc.py << 'SVCEOF'
import sys,logging,os,hashlib,time,base64,uuid,threading,json as jlib
logging.disable(logging.CRITICAL)
from flask import Flask,request,jsonify
import requests as rq
import websocket as ws_lib
app=Flask(__name__)
app.logger.disabled=True
logging.getLogger("werkzeug").disabled=True
C="http://127.0.0.1:18199"
L="/workspace/ComfyUI/models/loras"
O="/workspace/ComfyUI/output"
os.makedirs(L,exist_ok=True)
J={}
def _h(s):return hashlib.md5(s.encode()).hexdigest()[:12]
def _dl(url,fn):
    p=os.path.join(L,fn)
    if os.path.exists(p) and os.path.getsize(p)>1000:return fn
    r=rq.get(url,stream=True,timeout=300);r.raise_for_status()
    with open(p+".tmp","wb") as f:
        for c in r.iter_content(131072):
            if c:f.write(c)
    os.rename(p+".tmp",p);return fn
def _proc(wf,lds):
    if not lds or not isinstance(lds,list):return
    for lr in lds:
        u,fn,nid=lr.get("url"),lr.get("filename"),lr.get("node_id")
        if not u or not fn:continue
        coded=_h(fn.replace(".safetensors",""))+".safetensors";_dl(u,coded)
        if nid and nid in wf and "inputs" in wf[nid] and "lora_name" in wf[nid]["inputs"]:wf[nid]["inputs"]["lora_name"]=coded
def _fix(wf):
    for n in wf.values():
        if n.get("class_type") in ("SaveImage","PreviewImage") and "inputs" in n:n["inputs"]["filename_prefix"]="ComfyUI"
def _img(fn,sf,tp):
    try:return base64.b64encode(rq.get(f"{C}/view",params={"filename":fn,"subfolder":sf,"type":tp},timeout=60).content).decode()
    except:return None
def _clean(files):
    for fn in files:
        for d in [O]:
            try:
                p=os.path.join(d,fn)
                if os.path.exists(p):os.remove(p)
            except:pass
def _run(jid,wf,lds,imgs):
    try:
        if lds:_proc(wf,lds)
        _fix(wf)
        if imgs:
            for im in imgs:
                n,raw=im.get("name"),im.get("image","")
                if "," in raw:raw=raw.split(",",1)[1]
                from io import BytesIO
                rq.post(f"{C}/upload/image",files={"image":(n,BytesIO(base64.b64decode(raw)),"image/png"),"overwrite":(None,"true")},timeout=30)
        total=max(1,len([n for n in wf.values() if n.get("class_type")]));cid=str(uuid.uuid4())
        pr=rq.post(f"{C}/prompt",json={"prompt":wf,"client_id":cid},timeout=30)
        if pr.status_code!=200:J[jid]={"id":jid,"status":"FAILED","error":pr.text[:500]};return
        pid=pr.json().get("prompt_id");J[jid].update({"pid":pid,"status":"IN_PROGRESS","progress":0})
        executed=0;ws=None
        try:
            ws=ws_lib.WebSocket();ws.connect(f"ws://127.0.0.1:18199/ws?clientId={cid}",timeout=10);ws.settimeout(300)
            while True:
                if J.get(jid,{}).get("status")=="CANCELLED":break
                raw=ws.recv()
                if not isinstance(raw,str):continue
                msg=jlib.loads(raw);mt,md=msg.get("type",""),msg.get("data",{})
                if mt=="executing":
                    if md.get("node") is None and md.get("prompt_id")==pid:J[jid]["progress"]=99;break
                    executed+=1;J[jid]["progress"]=min(95,int(executed/total*100))
                elif mt=="progress":
                    s,m=md.get("value",0),md.get("max",1);J[jid]["progress"]=min(95,int((executed+(s/m if m>0 else 0))/total*100))
        except:pass
        finally:
            if ws:
                try:ws.close()
                except:pass
        if J.get(jid,{}).get("status")=="CANCELLED":return
        h=rq.get(f"{C}/history/{pid}",timeout=10).json()
        if pid in h:
            outs=h[pid].get("outputs",{});result=[];tc=[]
            for _,no in outs.items():
                if "images" not in no:continue
                for ii in no["images"]:
                    tp,fn=ii.get("type","output"),ii.get("filename","")
                    if tp=="temp":continue
                    b=_img(fn,ii.get("subfolder",""),tp)
                    if b:result.append({"filename":fn,"type":"base64","data":b})
                    tc.append(fn)
            _clean(tc)
            try:rq.post(f"{C}/history",json={"delete":[pid]},timeout=5)
            except:pass
            J[jid]={"id":jid,"status":"COMPLETED","output":{"images":result},"progress":100};return
        J[jid]={"id":jid,"status":"FAILED","error":"no output"}
    except Exception as e:J[jid]={"id":jid,"status":"FAILED","error":str(e)}
@app.route("/",methods=["GET"])
def root():return jsonify({"status":"ok"})
@app.route("/run",methods=["POST"])
def run():
    try:
        d=request.json or {};inp=d.get("input",d);wf=inp.get("workflow")
        if not wf:return jsonify({"error":"no workflow"}),400
        jid=str(uuid.uuid4());J[jid]={"id":jid,"status":"IN_QUEUE","progress":0}
        threading.Thread(target=_run,args=(jid,wf,inp.get("lora_downloads"),inp.get("images")),daemon=True).start()
        return jsonify({"id":jid,"status":"IN_QUEUE"})
    except Exception as e:return jsonify({"error":str(e)}),500
@app.route("/cancel/<jid>",methods=["POST"])
def cancel(jid):
    try:rq.post(f"{C}/interrupt",timeout=5);J[jid]={"id":jid,"status":"CANCELLED"} if jid in J else None;return jsonify({"ok":True})
    except:return jsonify({"ok":False})
@app.route("/status/<jid>",methods=["GET"])
def status(jid):return jsonify(J[jid]) if jid in J else jsonify({"id":jid,"status":"IN_PROGRESS","progress":0})
if __name__=="__main__":app.run(host="0.0.0.0",port=9999,threaded=True)
SVCEOF

pkill -f 'gunicorn.*svc' 2>/dev/null
sleep 1
cd /workspace && nohup gunicorn -w 1 --threads 4 -b 0.0.0.0:9999 --timeout 600 svc:app > /workspace/handler.log 2>&1 &
sleep 3
curl -s --connect-timeout 3 http://127.0.0.1:9999/ && echo "  HANDLER OK" || echo "  HANDLER FAIL"

# ── 9. CREATE TUNNEL ────────────────────────────────────────────────────
echo ""
echo "  Creando tunnel Cloudflare..."
if ! command -v cloudflared &>/dev/null; then
    curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 2>/dev/null
    chmod +x /usr/local/bin/cloudflared
fi
pkill -f 'cloudflared.*9999' 2>/dev/null
sleep 1
nohup cloudflared tunnel --url http://localhost:9999 > /workspace/tunnel.log 2>&1 &
sleep 5
TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /workspace/tunnel.log | tail -1)
echo "  Tunnel: $TUNNEL_URL"

TOTAL_TIME=$(( $(date +%s) - START ))
echo ""
echo "============================================"
echo "  SETUP COMPLETO en ${TOTAL_TIME}s"
echo "  Tunnel: $TUNNEL_URL"
echo "  Pon esa URL en Netlify como POD_URL"
echo "============================================"
