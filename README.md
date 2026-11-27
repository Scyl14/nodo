# Nodo

A local node for when the internet is gone. The console runs on a Debian machine, opens a Wi-Fi named Nodo, and serves this page at `http://10.41.0.1`. Phones nearby use it without a router and without a cloud account.

This repository starts with the console. The Debian installer and the VirtualBox image come after the console is usable.

## What you can do

- The owner sets a password on the machine and writes down a recovery code. There is no email reset.
- A neighbor asks to enter. The owner accepts or refuses each device.
- Home is a short board for people already on the Wi-Fi, plus battery, clock, and address.
- LLMs shows which model first boot would pick from memory. The small model stays installed so the node still works offline. This preview does not invent model replies. It searches a few local notes.
- Community explains two chats that are not this page. Bitchat is the phone app, no extra hardware, Android APK cached from the official release only. Meshtastic needs a LoRa board per person and only carries short text.
- Radio is FM broadcast, 87.5–108 MHz, and only if a USB receiver is plugged in. GPS sets the clock when a receiver has a fix.

## What this is not

Meshtastic is not an off-grid internet. It cannot open this console. A neighborhood of rooftop Wi-Fi routers can, later. Service-channel scanning is out. So is a web shell.

## Hardware, all optional

| Want | Need |
| --- | --- |
| Console, board, library | The computer only |
| Bitchat | Android phones. iPhone installs from the App Store while a network exists |
| Meshtastic | A LoRa board for each person, plus one on the computer if it should join |
| FM | A USB RTL-SDR |
| GPS time | A USB GPS receiver |

## Language

The repository and the console are in English.

## In this repository

Cloning these files does not install a node and does not open a Wi-Fi. The Debian installer and the VirtualBox image are not published yet.

| Path | What it is |
| --- | --- |
| `src/components/nodo/console.tsx` | The local web console |
| `src/lib/nodo/store.ts` | Owner password, neighbor approval, board, clock, radio presets |
| `src/lib/nodo/library.ts` | Short notes kept on the machine |
| `src/styles.css` | Colors and type |
| `public/favicon.svg` | The mark |
