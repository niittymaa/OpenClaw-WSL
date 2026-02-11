# Frequently Asked Questions

This guide covers common questions about setting up messaging channels and third-party services with OpenClaw.

---

## Signal Setup

### How do I set up Signal with OpenClaw?

Signal requires a separate registration process with `signal-cli` before OpenClaw can use it.

**Step 1: Register your phone number**
```bash
# In WSL (run: wsl -d openclaw)
signal-cli -u +YOURNUMBER register
```
Replace `+YOURNUMBER` with your full phone number including country code (e.g., `+358443290584`).

**Step 2: Verify with SMS code**
```bash
signal-cli -u +YOURNUMBER verify CODE_FROM_SMS
```

**Alternative: Voice verification**
If you can't receive SMS:
```bash
signal-cli -u +YOURNUMBER register --voice
```

### Why do I get "User is not registered" error?

```
[signal] signal-cli: User +358443290584 is not registered.
[signal] signal daemon not ready after 10223ms (This operation was aborted)
```

**Cause**: You entered your phone number in OpenClaw's config, but haven't completed Signal CLI registration.

**Solution**: Follow the registration steps above. Simply configuring your phone number is not enough—Signal requires you to verify ownership via SMS or voice call.

### Can I use Signal with my main phone number?

**Warning**: Signal only allows one device per phone number. If you register your main number with `signal-cli`, it will **deactivate Signal on your phone**.

**Recommendations**:
- Use a secondary phone number or SIM
- Use a virtual phone number service (Google Voice, etc.)
- Keep your main Signal on your phone and use a different number for OpenClaw

### Signal daemon keeps timing out

```
[signal] signal daemon not ready after 30000ms (This operation was aborted)
```

**Causes**:
1. Phone number not registered (see above)
2. `signal-cli` service not running
3. Network connectivity issues

**Check if signal-cli is working**:
```bash
signal-cli -u +YOURNUMBER receive
```

---

## WhatsApp Setup

### How do I connect WhatsApp?

1. Launch OpenClaw gateway (`OpenClaw.bat`)
2. A QR code appears in the terminal
3. On your phone: WhatsApp → Settings → Linked Devices → Link a Device
4. Scan the QR code

### Why does WhatsApp keep disconnecting?

```
[whatsapp] Web connection closed (status 503). Retry 1/12 in 2.29s…
```

**Common causes**:
- Internet connection instability
- WhatsApp session expired (re-scan QR code)
- Multiple WhatsApp Web sessions open

**Solutions**:
1. Check your internet connection
2. Close other WhatsApp Web sessions
3. Re-scan the QR code: `openclaw channel add whatsapp`
4. Run diagnostics: `openclaw doctor`

### "WhatsApp configured, not enabled yet"

This message from `openclaw doctor` means WhatsApp is set up but needs to be activated.

**Solution**:
```bash
openclaw doctor --fix
```

Or manually enable the channel in OpenClaw settings.

---

## Telegram Setup

### How do I set up Telegram?

1. Create a Telegram Bot via [@BotFather](https://t.me/botfather)
2. Get your bot token
3. Add Telegram channel in OpenClaw:
   ```bash
   openclaw channel add telegram
   ```
4. Enter your bot token when prompted

### How do I find my Telegram chat ID?

1. Message your bot on Telegram
2. Check OpenClaw logs for your chat ID
3. Or use [@userinfobot](https://t.me/userinfobot)

---

## General Channel Questions

### Which messaging platforms does OpenClaw support?

- **WhatsApp** — Via WhatsApp Web protocol (Baileys)
- **Signal** — Via signal-cli
- **Telegram** — Via Bot API
- **Discord** — Via Discord Bot
- **Webchat** — Built-in web interface

### Can I use multiple channels at once?

Yes! OpenClaw can connect to multiple channels simultaneously. Configure each channel separately.

### Where are my session credentials stored?

All channel credentials and sessions are stored inside WSL:
```
~/.openclaw/
├── whatsapp-sessions/    # WhatsApp linked device session
├── signal/               # Signal CLI data
└── openclaw.json         # Main configuration
```

---

## AI Provider Questions

### How do I change AI providers or models?

Manage models and providers directly inside OpenClaw via CLI:
```bash
# In WSL (run: wsl -d openclaw)
openclaw models set anthropic/claude-sonnet-4   # Change model
openclaw models auth add                        # Add new provider (interactive)
openclaw models status                          # View current model and auth
```

### Do I need an API key?

- **Cloud providers** (Anthropic, OpenAI, OpenRouter): Yes, API key required
- **Ollama** (local): No API key needed, runs entirely on your machine

### How do I use Ollama for local AI?

1. Install Ollama on Windows: https://ollama.com/download
2. Pull a model: `ollama pull llama3.1:8b`
3. In OpenClaw, run `Start.bat` → Settings → Configure Ollama
4. Enable mirrored networking when prompted (required for WSL to reach Ollama)

See [TROUBLESHOOT.md](TROUBLESHOOT.md#wsl-cannot-reach-ollama) if WSL can't connect to Ollama.

---

## Memory and Plugin Issues

### "memory slot plugin not found: memory-core"

```
[gateway] [plugins] memory slot plugin not found or not marked as memory: memory-core
```

This is a **warning**, not an error. It means the optional memory plugin isn't installed. OpenClaw will work fine without it.

**To install memory plugin** (optional):
```bash
openclaw skill install memory-core
```

---

## Getting Help

### Where can I find more help?

- **Technical issues**: See [TROUBLESHOOT.md](TROUBLESHOOT.md)
- **Getting started**: See [QUICKSTART.md](QUICKSTART.md)
- **OpenClaw documentation**: https://openclaw.im/docs
- **signal-cli documentation**: https://github.com/AsamK/signal-cli

### How do I run diagnostics?

```bash
# Check OpenClaw configuration
openclaw doctor

# Auto-fix common issues
openclaw doctor --fix

# Check status
openclaw status
```
