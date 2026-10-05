# Volter
Lightweight menubar app for managing your Apple silicon Mac's GPU power and controlling sleep. 

<img width="364" height="161" alt="image" src="https://github.com/user-attachments/assets/12606b2c-3a47-4c5a-a99f-c5175c111570" />

**How it works**: 
- Minimal version of [maderix](https://github.com/maderix/apple-gpu-dvfs)'s GPU wattage controller, which accesses private IOKit APIs
- Keeps the system awake even when the lid is closed using `pmset`, and keeps the display (and compositor) awake with an idle-display-sleep assertion
- Stealth mode (available only when sleep is disabled) locks the screen as soon as the lid opens via the private SAC lock API (`pmset displaysleepnow` fallback), while the system stays awake so remote sessions survive
- Persistent helper that only requires password on first apply
