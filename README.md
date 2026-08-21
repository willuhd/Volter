# Volter
Lightweight menubar app for managing your x86 Mac's power. 

<img width="312" height="202" alt="image" src="https://github.com/user-attachments/assets/bc8cfeef-01d5-45cb-9789-aafe6dbe356a" />

**How it works**: 
- Modified lightweight VoltageShift binary for better dynamic kext loading (can load from Resources as opposed to a predefined path), also applies using an optimized `438...` hex (instead of `428...`) so the iGPU won't starve the CPU's power in a limited envelope
- hholtmann's smcFanControl `smc` binary for fan speed management to speeds beyond the system's allowed limits (even with T2)
- Persistent privileged helper tool with lazy kext loading, so only the first apply requires password entry and extra time; subsequent applies are near-instant 
