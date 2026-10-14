#!/usr/bin/env bash
# vps.sh — let OpenCode agents (and humans) talk to the training VPS.
# Config via env (export or .env file sourced by your shell):
#   ssh mode:         VPS_USER VPS_HOST VPS_PORT=22 VPS_KEY=~/.ssh/id_vps VPS_DIR=~/jetdb
#   cloud-shell mode: VPS_MODE=cloudshell VPS_DIR=~/jetdb  (Mac talks via gcloud CLI)
set -euo pipefail

need_config() { # aborts with a clear message when VPS env is missing
  VPS_MODE="${VPS_MODE:-ssh}" # ssh | cloudshell
  if [ "$VPS_MODE" = "cloudshell" ]; then
    command -v gcloud >/dev/null || { echo "install gcloud CLI: https://cloud.google.com/sdk/docs/install"; exit 1; }
    VPS_DIR="${VPS_DIR:-~/jetdb}"
    return
  fi
  VPS_USER="${VPS_USER:?set VPS_USER}"; VPS_HOST="${VPS_HOST:?set VPS_HOST}"
  VPS_PORT="${VPS_PORT:-22}"; VPS_KEY="${VPS_KEY:-}"; VPS_DIR="${VPS_DIR:-~/jetdb}"
  SSH=(ssh -p "$VPS_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  [ -n "$VPS_KEY" ] && SSH+=( -i "$VPS_KEY" )
  DST="$VPS_USER@$VPS_HOST"
}

# Dataset dirs relative to repo root (deduplicated: no quick_jets raws, no archive.zip, no kaggle_full* staging)
DATA_DIRS=(archive/sample_meta.csv sample_meta.csv esc50_tmp desed_train drone_audio
  yt_flybys_5s yt_flybys2_5s yt_flybys3_5s abbotsford_5s f16_5s auto_5s sonic_booms archive/audio)

usage() { sed -n '2,40p' "$0" | grep '^#'; echo "usage: vps.sh {doctor|exec|put|get|sync-data|gpu|train|logs|pull-model} [...]"; }
runcmd() { # runcmd <cmd...> — run on VPS, stdout back here (ssh or gcloud transport)
  if [ "${VPS_MODE:-ssh}" = "cloudshell" ]; then gcloud cloud-shell ssh --authorize-session --command="$*"
  else "${SSH[@]}" "$DST" "$@"; fi
}
putfile() { # putfile <local> <remote-path>
  if [ "${VPS_MODE:-ssh}" = "cloudshell" ]; then gcloud cloud-shell scp "$1" ":$2"
  else scp -P "$VPS_PORT" ${VPS_KEY:+-i "$VPS_KEY"} "$1" "$DST:$2"; fi
}
getfile() { # getfile <remote-path> <local>
  if [ "${VPS_MODE:-ssh}" = "cloudshell" ]; then gcloud cloud-shell scp ":$1" "$2"
  else scp -P "$VPS_PORT" ${VPS_KEY:+-i "$VPS_KEY"} "$DST:$1" "$2"; fi
}
cmd="${1:-help}"; shift || true
[ "$cmd" != "help" ] && need_config
case "$cmd" in
  help) usage ;;
  doctor) # local + remote connectivity checks (no secrets printed)
    if [ "${VPS_MODE:-ssh}" = "cloudshell" ]; then command -v gcloud python3 >/dev/null && echo "local: gcloud python3 OK"
    else command -v ssh rsync python3 >/dev/null && echo "local: ssh rsync python3 OK"; fi
    runcmd 'echo remote: $(whoami)@$(hostname) $(python3 -c "import torch;print(\"torch\",torch.__version__,\"cuda\",torch.cuda.is_available())" 2>/dev/null || echo no-torch)'
    ;;
  exec) # vps.sh exec -- <command...>  (everything after -- runs on the VPS)
    [ "${1:-}" = "--" ] && shift
    runcmd "$@" ;;
  put) # vps.sh put <local> <remote-path>
    putfile "$1" "$2" ;;
  get) # vps.sh get <remote-path> <local>
    getfile "$1" "$2" ;;
  sync-data) # vps.sh sync-data [--from]  (default Mac->VPS; --from pulls VPS->Mac)
    if [ "${VPS_MODE:-ssh}" = "cloudshell" ]; then
      for d in "${DATA_DIRS[@]}"; do # no rsync over this transport: scp --recurse per dir
        [ -e "$d" ] || { echo "skip missing: $d"; continue; }
        gcloud cloud-shell scp --recurse "$d" ":$VPS_DIR/"
      done
    elif [ "${1:-}" = "--from" ]; then
      rsync -av --progress -e "ssh -p $VPS_PORT" "$DST:$VPS_DIR/" ./vps_inbox/
    else
      for d in "${DATA_DIRS[@]}"; do [ -e "$d" ] || echo "skip missing: $d"; done
      rsync -av --progress -e "ssh -p $VPS_PORT" "${DATA_DIRS[@]}" "$DST:$VPS_DIR/"
    fi ;;
  gpu) # vps.sh gpu  (nvidia-smi + torch cuda check; Cloud Shell has no GPU)
    runcmd 'nvidia-smi --query-gpu=name,memory.total --format=csv 2>/dev/null || echo no-nvidia-smi; python3 -c "import torch;print(\"cuda:\",torch.cuda.is_available())"' ;;
  train) # vps.sh train [--epochs 20]  (rebuild manifest, launch detached, stream log)
    runcmd "cd $VPS_DIR && python3 combine_datasets.py && (tmux new-session -d -s v3 'python3 train_v3.py $* 2>&1 | tee v3.log' 2>/dev/null || nohup python3 train_v3.py $* > v3.log 2>&1 &) && echo launched" ;;
  logs) # vps.sh logs [-f]  (tail training log)
    if [ "${1:-}" = "-f" ]; then runcmd "tail -f $VPS_DIR/v3.log"; else runcmd "tail -30 $VPS_DIR/v3.log"; fi ;;
  pull-model) # vps.sh pull-model  (fetch v3_jet.pt + history_v3.csv to repo root)
    getfile "$VPS_DIR/v3_jet.pt" ./v3_jet.pt; getfile "$VPS_DIR/history_v3.csv" ./history_v3.csv && python3 make_plots_hq.py ;;
  *) usage; exit 1 ;;
esac
