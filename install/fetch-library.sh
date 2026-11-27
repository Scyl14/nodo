#!/bin/bash
# Download the public library and index it. Does not touch the model or the map.
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { printf 'Run as root: sudo ./install/fetch-library.sh [everything|essentials]\n' >&2; exit 1; }
choice="${1:-everything}"
[[ "$choice" == "everything" || "$choice" == "essentials" ]] || { printf 'Use everything or essentials.\n' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git python3 python3-venv python3-pip python3-dev build-essential

if [[ ! -d /opt/nodo/survival-llm/.git ]]; then
  git clone --depth 1 https://github.com/anonnerdfrenzy/survival-llm.git /opt/nodo/survival-llm
else
  git -C /opt/nodo/survival-llm pull --ff-only || true
fi
python3 -m venv /opt/nodo/survival-llm/.venv
/opt/nodo/survival-llm/.venv/bin/pip install -U pip
/opt/nodo/survival-llm/.venv/bin/pip install libzim lxml trafilatura

zims=(
  wikipedia_en_medicine
  wikem_en_all
  appropedia_en_all
  medlineplus.gov_en_all
  nhs.uk_en_medicines
  wwwnc.cdc.gov_en_all
  ready.gov_en_all
  usda-2015_en
  wikiciv_en_all
  gardenology.org_en_all
  energypedia_en_all
  diy.stackexchange.com_en_all
  outdoors.stackexchange.com_en_all
  cooking.stackexchange.com_en_all
  gardening.stackexchange.com_en_all
  lifehacks.stackexchange.com_en_all
  sustainability.stackexchange.com_en_all
  ham.stackexchange.com_en_all
  medicalsciences.stackexchange.com_en_all
  mechanics.stackexchange.com_en_all
  pets.stackexchange.com_en_all
)
if [[ "$choice" == "everything" ]]; then
  zims+=(wikipedia_en_top1m ifixit_en_all)
fi

cd /opt/nodo/survival-llm
python3 - "${zims[@]}" <<'PY'
import os, re, subprocess, sys, urllib.request
wanted = set(sys.argv[1:])
prefer = {
    "wikipedia_en_medicine": "nopic",
    "wikem_en_all": "nopic",
    "appropedia_en_all": "maxi",
    "wikiciv_en_all": "maxi",
    "energypedia_en_all": "nopic",
    "wikipedia_en_top1m": "nopic",
}
root = "/opt/nodo/survival-llm/library.noindex/zim"
os.makedirs(root, exist_ok=True)
catalog = urllib.request.urlopen(
    "https://library.kiwix.org/catalog/v2/entries?lang=eng&count=5000", timeout=120).read().decode()
found = {}
for entry in re.findall(r"<entry>(.*?)</entry>", catalog, re.S):
    name = re.search(r"<name>(.*?)</name>", entry)
    flavour = re.search(r"<flavour>(.*?)</flavour>", entry)
    link = re.search(r'rel="http://opds-spec.org/acquisition/open-access"[^>]*href="([^"]+)"', entry)
    if not (name and link) or name.group(1) not in wanted:
        continue
    found.setdefault(name.group(1), {})[flavour.group(1) if flavour else ""] = link.group(1).removesuffix(".meta4")
for name in sys.argv[1:]:
    choices = found.get(name) or {}
    url = choices.get(prefer.get(name, "")) or next(iter(choices.values()), "")
    if not url:
        print(f"skip {name}: not in the catalog", flush=True)
        continue
    dest = os.path.join(root, url.rsplit("/", 1)[1])
    if os.path.exists(dest + ".done"):
        print(f"already fetched {name}", flush=True)
        continue
    print(f"downloading {name}", flush=True)
    result = subprocess.run(["curl", "-L", "--fail", "-C", "-", "--retry", "3", "--connect-timeout", "30", "-o", dest, url])
    if result.returncode != 0:
        print(f"warning: {name} failed, continuing", flush=True)
        continue
    open(dest + ".done", "w").close()
    print(f"fetched {name}", flush=True)
PY
python3 library/fetch_manuals.py || printf 'warning: the manuals were not fetched\n'
python3 library/fetch_risk.py || printf 'warning: the risk notes were not fetched\n'

install -d -m 0755 /var/lib/nodo/library
if [[ "$choice" == "everything" ]]; then
  LIBRARY_OUT=/var/lib/nodo/library .venv/bin/python library/build_library.py --public
else
  LIBRARY_OUT=/var/lib/nodo/library .venv/bin/python library/build_library.py --public --lite
fi
if [[ ! -f /var/lib/nodo/library/index.sqlite ]]; then
  printf 'The index was not written to /var/lib/nodo/library/index.sqlite\n' >&2
  exit 1
fi
printf 'Library ready. Reload the Library tab.\n'
