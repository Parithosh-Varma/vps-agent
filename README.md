# vps-agent — Talk to the Training VPS from OpenCode

![bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)
![ssh](https://img.shields.io/badge/transport-ssh%20%7C%20gcloud-blue?logo=openssh&logoColor=white)
![platform](https://img.shields.io/badge/platform-macos%20%2B%20linux-lightgrey)
![pytorch](https://img.shields.io/badge/remote-torch%20%2B%20cuda-EE4C2C?logo=pytorch&logoColor=white)
![status](https://img.shields.io/badge/status-active-brightgreen)

> **Tags:** `opencode` `vps` `ssh` `gcloud` `cloud-shell` `gce` `training` `pytorch` `cuda` `tmux` `rsync` `jet-classifier` `remote-exec`

One wrapper for humans and agents: `tools/vps-agent/vps.sh`.

Never stores secrets — connection comes from the environment (`VPS_USER`, `VPS_HOST`, `VPS_PORT`, `VPS_KEY`, `VPS_DIR`, `VPS_MODE`). Copy `.env.example` to `~/.vpsrc`, never commit real values.

<!-- keywords: vps-agent, remote training, ssh wrapper, gcloud cloud-shell, jetdb, train_v3, opencode agent -->

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Setup](#setup)
  - [SSH VPS (GPU / full DB)](#ssh-vps-gpu--full-db)
  - [Google Cloud Shell (CPU / no inbound SSH)](#google-cloud-shell-cpu--no-inbound-ssh)
- [Agent workflow](#agent-workflow)
- [Commands](#commands)
- [Data sync details](#data-sync-details)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Sharing](#sharing)

## Features

- Single entrypoint (`vps.sh`) usable from a shell prompt or an OpenCode agent step.
- Two transports: plain **SSH** (`VPS_MODE=ssh`) and **Cloud Shell via `gcloud`** (`VPS_MODE=cloudshell`).
- Dataset sync with deduplication, detached GPU training (`tmux`/`nohup`), log tailing, and one-command model pullback.
- No secrets on disk in the repo; `doctor` prints connectivity only, never keys.

## Requirements

| Requirement | SSH mode | Cloud Shell mode |
|---|---|---|
| Local tools | `ssh`, `rsync`, `python3` | `gcloud`, `python3` |
| Auth | SSH key on VPS (`ssh-copy-id` once) | `gcloud auth login` + authorized session |
| Remote | Python 3 + `torch` (CUDA optional) | Python 3 + `torch` (CPU only) |

## Setup

Each human + agent host runs this once.

### SSH VPS (GPU / full DB)

```bash
cp tools/vps-agent/.env.example ~/.vpsrc   # edit with real host/key
source ~/.vpsrc                             # or: export VPS_USER=... VPS_HOST=...
chmod +x tools/vps-agent/vps.sh
tools/vps-agent/vps.sh doctor               # expect: local OK + remote line
```

SSH key auth required (once per client):

```bash
ssh-copy-id -i ~/.ssh/id_vps user@host
```

`doctor` prints no secrets — just `local: ... OK` and a `remote: user@host torch ... cuda ...` (or `no-torch`) line.

Config used in this mode:

```bash
VPS_MODE=ssh VPS_USER=ubuntu VPS_HOST=203.0.113.10 VPS_PORT=22 VPS_KEY=~/.ssh/id_vps VPS_DIR=~/jetdb
```

### Google Cloud Shell (CPU / no inbound SSH)

Use when the Mac can't SSH inbound — it talks via the `gcloud` CLI instead.

```bash
# Mac, once: install the gcloud CLI, then
gcloud auth login
gcloud cloud-shell ssh --authorize-session --command="echo ok"
# point vps-agent at it (no USER/HOST/KEY needed)
export VPS_MODE=cloudshell VPS_DIR=~/jetdb
tools/vps-agent/vps.sh doctor
```

Cloud Shell limits to know:

- **5 GB persistent `$HOME`** — the full ~4.6 GB DB barely fits; sync a subset first (e.g. aerosonic only).
- **No GPU** — CPU train only, slow.
- Idle sessions can be reclaimed — `train` launches detached via `tmux`/`nohup`, `logs` reattaches.

For the full DB + GPU, use a GCE VM with a static IP instead (same tool, `VPS_MODE=ssh`).

## Agent workflow

Full v3 run from this repo:

```bash
tools/vps-agent/vps.sh gpu                 # is there CUDA?
tools/vps-agent/vps.sh sync-data           # Mac -> VPS, ~4.6GB first time
tools/vps-agent/vps.sh train -- --epochs 20
tools/vps-agent/vps.sh logs -f             # stream; Ctrl-C detaches safely
tools/vps-agent/vps.sh pull-model          # v3_jet.pt + history_v3.csv -> . + acc_v3.png
```

## Commands

| Command | Does |
|---|---|
| `doctor` | Local deps + SSH/`gcloud` + remote `torch` check |
| `exec -- <cmd>` | Run anything on the VPS, output back here |
| `put <local> <remote>` / `get <remote> <local>` | Single-file copy |
| `sync-data [--from]` | `rsync` dataset dirs (skips dupes: `quick_jets`, `archive.zip`, `kaggle_full*`); `--from` pulls VPS → `./vps_inbox/` |
| `gpu` | `nvidia-smi` + `torch.cuda.is_available()` (Cloud Shell reports no GPU) |
| `train [--epochs N]` | `combine_datasets.py` (fixes VPS paths) + detached `train_v3.py` via `tmux`/`nohup` |
| `logs [-f]` | `tail` `v3.log` (`-f` streams) |
| `pull-model` | Fetch `v3_jet.pt` + `history_v3.csv` to repo root, then run `make_plots_hq.py` |
| `help` | Print usage from script header |

Extra examples:

```bash
tools/vps-agent/vps.sh exec -- nvidia-smi
tools/vps-agent/vps.sh put ./train_v3.py ~/jetdb/train_v3.py
tools/vps-agent/vps.sh get ~/jetdb/v3.log ./v3-remote.log
tools/vps-agent/vps.sh sync-data --from   # pull remote outputs to ./vps_inbox/
tools/vps-agent/vps.sh logs               # last 30 lines without following
```

## Data sync details

Synced dirs (`DATA_DIRS` in `vps.sh`), relative to repo root:

```text
archive/sample_meta.csv sample_meta.csv esc50_tmp desed_train drone_audio
yt_flybys_5s yt_flybys2_5s yt_flybys3_5s abbotsford_5s f16_5s auto_5s
sonic_booms archive/audio
```

- SSH mode uses `rsync -av --progress`; missing local dirs print `skip missing: <dir>`.
- Cloud Shell mode has no `rsync` transport — falls back to `gcloud cloud-shell scp --recurse` per dir.
- Raw/staging dupes (`quick_jets`, `archive.zip`, `kaggle_full*`) are intentionally excluded.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `set VPS_USER` / `set VPS_HOST` | `source ~/.vpsrc` first, or export the vars |
| `install gcloud CLI` | Install from <https://cloud.google.com/sdk/docs/install>, then `gcloud auth login` |
| SSH hangs / timeout | Check `VPS_HOST`/`VPS_PORT`, security-group ingress, and `ssh -p <port> -i <key> user@host` manually |
| `no-torch` from `doctor` | `pip install torch` on the VPS (CPU wheel is fine for a connectivity check) |
| `no-nvidia-smi` from `gpu` | Expected on CPU-only hosts / Cloud Shell |

## Security

- Secrets live only in env / `~/.vpsrc` — never in the repo.
- SSH uses `BatchMode=yes`, `StrictHostKeyChecking=accept-new`, 10 s connect timeout.
- `doctor` / `gpu` output contains no keys or paths beyond `VPS_DIR`.

## Sharing

Commit this directory; teammates source their own `~/.vpsrc` pointing at the same (or their own) VPS. Nothing host-specific is hardcoded.

Related: [`vps.sh`](./vps.sh) · [`.env.example`](./.env.example)
