# Volter
Lightweight menubar app for managing your x86 Mac's power. 

<img width="312" height="202" alt="image" src="https://github.com/user-attachments/assets/bc8cfeef-01d5-45cb-9789-aafe6dbe356a" />

**How it works**: 
- Modified lightweight VoltageShift binary for better kext loading, using an optimized `438...` hex (instead of `428...`) so the iGPU won't starve the CPU's power in a limited envelope
- hholtmann's smcFanControl `smc` binary for fan speed management to speeds beyond the system's allowed limits (even with T2!)
