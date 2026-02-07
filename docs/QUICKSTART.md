# OpenClaw Quick Start Guide

This guide walks you through getting OpenClaw working after installation via OpenClaw-WSL.

## Overview

OpenClaw is a **self-hosted AI assistant** that you control via WhatsApp, Telegram, Discord, or other messaging platforms. You message **your own number**, and OpenClaw—running locally—responds as your personal AI agent.

**Key Concept**: You send messages to yourself (your own WhatsApp number). OpenClaw intercepts these via WhatsApp Web protocol and responds through the same chat. It's like having a private AI that lives in your phone's chat app.

---

## Step 1: Launch OpenClaw

After installation, use one of these methods:

### Option A: Direct launch (recommended)
Double-click in the root folder:
```
OpenClaw.bat
```
This directly starts the OpenClaw gateway.

### Option B: Via management menu
Double-click:
```
Start.bat
```
Then select **"Launch OpenClaw"** from the menu.

### Option C: Create a shortcut
Right-click `OpenClaw.bat` → **Create shortcut** → Move to Desktop for easy access.

---

## Step 2: Complete Setup (First Time Only)

If you haven't completed setup during installation, use the management menu:

1. Run `Start.bat`
2. Select **"Settings"**
3. Select **"OpenClaw Setup"**

The wizard will guide you through:

1. **AI Provider Selection** — Choose your AI backend (Anthropic Claude, OpenAI GPT, local Ollama, etc.)
2. **API Key Entry** — Enter your API key for the selected provider
3. **Channel Setup** — Add WhatsApp (or other messaging platforms)

You can also run setup again anytime from the Settings menu to change your configuration.

---

## Step 3: Connect WhatsApp

When you add WhatsApp as a channel:

1. A **QR code** appears in your terminal
2. Open WhatsApp on your phone → **Settings** → **Linked Devices** → **Link a Device**
3. Scan the QR code with your phone
4. Wait for connection confirmation

Your session credentials are stored in `~/.openclaw/whatsapp-sessions` inside WSL for automatic reconnection.

---

## Step 4: Start Chatting

Once connected:

1. Open WhatsApp on your phone
2. Start a chat with **yourself** (your own phone number)
3. Type any message — OpenClaw will respond as your AI assistant

### Example messages:
- "What's the weather in Tokyo?"
- "Summarize this article: [paste URL]"
- "Set a reminder for 3pm"
- "Search my files for invoices from last month"

---

## Step 5: Keep It Running

For 24/7 availability, keep the gateway running:

### Background operation
Leave the terminal window open, or run as a daemon:
```bash
# Inside WSL
openclaw gateway --daemon
```

### Check status
```bash
openclaw status
```

---

## Useful Commands

Run commands inside WSL using `Start.bat` → open shell, or:

```powershell
wsl.exe -d "openclaw" -- bash -lc "openclaw status"
```

| Command | Description |
|---------|-------------|
| `openclaw status` | Check if OpenClaw is running and connected |
| `openclaw doctor` | Diagnose configuration issues |
| `openclaw gateway logs` | View recent activity logs |
| `openclaw channel list` | List connected messaging channels |
| `openclaw channel add` | Add a new channel (WhatsApp, Telegram, etc.) |

---

## Management Menu (Start.bat)

The management menu provides these options:

| Option | Description |
|--------|-------------|
| **Launch OpenClaw** | Start the OpenClaw gateway |
| **Settings** | Access configuration submenu |
| **Update Scripts** | Pull latest OpenClaw-WSL updates |
| **Uninstall OpenClaw** | Remove WSL distribution and data |

### Settings Submenu

| Option | Description |
|--------|-------------|
| **AI Provider & Models** | Switch AI providers, change models, add API keys |
| **OpenClaw Setup** | Quick configuration check |
| **Run Onboarding Wizard** | Full guided setup for AI, API keys, channels |
| **Launcher Settings** | Configure banner title, browser, startup options |
| **Configure Ollama** | Set up Ollama WSL networking for local models |

---

## Changing AI Providers

OpenClaw supports multiple AI providers. Use `Start.bat` → **Settings** → **AI Provider & Models** to:

1. **List Available Models** — See all models from your configured providers
2. **Change Model** — Switch to a different model (e.g., `anthropic/claude-opus-4-5`, `openai/gpt-4o`, `ollama/llama3.2`)
3. **Auto-Select Best** — Let OpenClaw scan providers and pick the best available
4. **Add Provider / API Key** — Configure authentication for new providers
5. **Enable/Disable Ollama** — Toggle local Ollama integration on or off

### Supported Providers
- **Anthropic** (Claude models) — Requires `ANTHROPIC_API_KEY`
- **OpenAI** (GPT models) — Requires `OPENAI_API_KEY`
- **Ollama** (Local models) — No API key needed, runs locally
- **OpenRouter** — Access to many models via single API

### Command Line Alternative
You can also manage providers directly in WSL:
```bash
openclaw models list      # List all available models
openclaw models status    # Show current model and auth status
openclaw models set anthropic/claude-opus-4-5  # Change model
openclaw models auth add  # Add provider authentication
```

---

## Updating OpenClaw

### Update OpenClaw package
```powershell
wsl.exe -d "openclaw" -- bash -lc "npm update -g openclaw"
```

### Update OpenClaw-WSL scripts
Run `Start.bat` → **Update Scripts**

---

## How It Works (Technical)

```
┌──────────────┐      ┌─────────────────┐      ┌──────────────┐
│  Your Phone  │ ───▶ │ WhatsApp Servers│ ───▶ │ OpenClaw     │
│  (WhatsApp)  │ ◀─── │                 │ ◀─── │ (WSL/Local)  │
└──────────────┘      └─────────────────┘      └──────────────┘
                                                      │
                                                      ▼
                                               ┌──────────────┐
                                               │  AI Provider │
                                               │ (Claude/GPT) │
                                               └──────────────┘
```

1. You send a WhatsApp message to your own number
2. OpenClaw receives it via WhatsApp Web protocol (Baileys library)
3. Your message is processed by the AI provider
4. The response is sent back through WhatsApp

**Privacy**: Everything runs locally on your machine. Only AI API calls go to external servers (unless you use a local model like Ollama).

---

## Troubleshooting

### QR Code won't scan
- Ensure your terminal supports Unicode characters
- Try maximizing the terminal window
- Run `openclaw channel add whatsapp` to regenerate

### WhatsApp disconnects frequently
- Check internet stability
- Session may have expired — re-scan QR code
- Run `openclaw doctor` for diagnostics

### "Command not found: openclaw"
The npm global path may not be in your PATH. Fix:
```bash
export PATH="$HOME/.npm-global/bin:$PATH"
```

### Need to reconfigure
Use `Start.bat` → **Settings** → **OpenClaw Setup** to change your configuration.

Or from the command line:
```bash
openclaw setup
```

---

## File Locations

| Location | Purpose |
|----------|---------|
| `OpenClaw.bat` | Direct launcher for OpenClaw gateway |
| `Start.bat` | Management menu (install, configure, launch) |
| `.local/data/` | Shared folder (mounted at `/mnt/openclaw-data` in WSL) |
| `.local/logs/` | Installation and runtime logs |
| `.local/wsl/` | WSL virtual disk |
| `~/.openclaw/` (in WSL) | OpenClaw config and session data |

---

## Next Steps

- **Add more channels**: Telegram, Discord, iMessage
- **Install skills**: Extend capabilities via `openclaw skill install <name>`
- **Configure agents**: Customize behavior in `~/.openclaw/config.yaml`
- **Local AI**: Use Ollama for fully offline operation

For detailed documentation, visit: https://openclaw.im/docs
