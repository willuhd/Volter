# Volter
Lightweight menubar app for managing your Apple silicon Mac's GPU power and controlling sleep. 

<img width="364" height="161" alt="image" src="https://github.com/user-attachments/assets/12606b2c-3a47-4c5a-a99f-c5175c111570" />

**How it works**: 
- Minimal version of [maderix](https://github.com/maderix/apple-gpu-dvfs)'s GPU wattage controller, which accesses private IOKit APIs
- Keeps the system awake even when the lid is closed using `pmset`
- Stealth mode (available only when sleep is disabled) uses an IORegistry listener to re-enable sleep when clamshell state exits, locking the screen as soon as the lid opens (sleep is re-disabled immediately and repeats until Stealth mode is turned off)
- Persistent helper that only requires password on first apply
