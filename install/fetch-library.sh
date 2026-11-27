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
  wikipedia_en_medicine_nopic
  wikem_en_all_nopic
  appropedia_en_all_maxi
  medlineplus.gov_en_all
  nhs.uk_en_medicines
  wwwnc.cdc.gov_en_all
  ready.gov_en_all
  usda-2015_en
  wikiciv_en_all_maxi
  gardenology.org_en_all
  energypedia_en_all_nopic
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
  zims+=(wikipedia_en_top1m_nopic ifixit_en_all)
fi

cd /opt/nodo/survival-llm
for name in "${zims[@]}"; do
  printf 'Fetching %s\n' "$name"
  python3 library/fetch_zims.py "$name" || printf 'warning: %s was not fetched\n' "$name"
done
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
