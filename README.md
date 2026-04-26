# Micro-TPM v3 — Open-Frame SKY130 Tapeout
**Target: ≤ 0.6 mm² | 5 GPIO pins | SKY130 HD | LibreLane**

---

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │              tpm_top.v                      │
    spi_csn  ──────►│                                             │
    spi_sck  ──────►│  tpm_spi_slave                             │
    spi_mosi ──────►│  (4-wire SPI, byte-stream protocol)        │
    spi_miso ◄──────│       │ port A (byte r/w)                   │
    irq      ◄──────│       │                                     │
                    │  tpm_mem (256 bytes)                        │
                    │       │ 0x00-0x7F = CMD_BUF                 │
                    │       │ 0x80-0xFF = RSP_BUF                 │
                    │       │ port B (byte r/w)                   │
                    │       │                                     │
                    │  tpm_cmd_proc (main FSM)                    │
                    │    │       │         │                      │
                    │  SHA-256  TRNG    PCR bank                  │
                    │  wrap     (3 RO)  (4×256-bit)               │
                    │    │                                        │
                    │  sha256_core (secworks RTL)                 │
                    └─────────────────────────────────────────────┘

External pins: clk, rstn, spi_csn, spi_sck, spi_mosi, spi_miso, irq
```

## How SHA-256 Is Used (Important)

There is **one** `sha256_core` instance in the design. The command processor
calls it sequentially for every cryptographic operation:

### PCR_Extend — 1 SHA-256 call
```
input block (512 bits) = PCR_current[255:0] || measurement[255:0]
                       = 64 bytes exactly = 1 SHA-256 block, no padding needed

sha256_core( block ) → new PCR value
```

### HMAC-SHA256 — 4 sequential SHA-256 block calls
```
HMAC(K, M) = SHA256( opad_K || SHA256( ipad_K || M ) )

Key K = 32 bytes, padded to 64 bytes with zeros, then XOR with ipad/opad.
ipad  = 0x3636363636...36  (64 bytes)
opad  = 0x5C5C5C5C5C...5C  (64 bytes)

ipad_block = (K ^ ipad32) || ipad32     [512 bits = 64 bytes]
opad_block = (K ^ opad32) || opad32     [512 bits = 64 bytes]

─── Inner hash ───────────────────────────────────
Call 1:  sha256_core( ipad_block )         first=1, last=0   [absorb]
Call 2:  sha256_core( M[255:0] || 0..0 )   first=0, last=1   [finalize]
         → inner_digest  (SHA256 of 96-byte message)

─── Outer hash ───────────────────────────────────
Call 3:  sha256_core( opad_block )             first=1, last=0   [absorb]
Call 4:  sha256_core( inner_digest || 0..0 )   first=0, last=1   [finalize]
         → HMAC result
```

**Zero extra hardware.** HMAC reuses the SHA-256 core four times in sequence.
The command processor FSM orchestrates the sequence; the SHA-256 wrapper just
exposes a simple start/done handshake.

---

## GPIO Pin Usage

| Pin | I/O | Signal | Notes |
|---|---|---|---|
| `spi_csn` | Input | Chip-select | Active-low |
| `spi_sck` | Input | SPI clock | Mode 0 (idle low, sample rising) |
| `spi_mosi` | Input | Host → chip | MSB first |
| `spi_miso` | Output | Chip → host | MSB first |
| `irq` | Output | Interrupt | High = response ready |

**5 pins used total.** All other GPIO pins on the padframe are unused.

---

## SPI Protocol

### WRITE (host sends command)
```
CSn  ─┐                                      ┌─
       └─────────────────────────────────────┘
MOSI    [0xC0] [byte0] [byte1] ... [byteN-1]
         opcode  command bytes (TPM format)

On CSn rising edge → command processor starts automatically.
IRQ goes high when response is ready.
```

### READ (host reads response)
```
CSn  ─┐                                      ┌─
       └─────────────────────────────────────┘
MOSI    [0x40] [0xFF]  [0xFF]  ... [0xFF]
         opcode  dummy bytes
MISO    [----] [rsp0]  [rsp1]  ... [rspN-1]

On CSn rising edge → IRQ clears.
```

**Maximum SPI clock:** sys_clk / 5 (10 MHz at 50 MHz sys_clk)

---

## Supported Commands

### TPM2_GetRandom — 0x017B
Returns random bytes from the hardware TRNG.

**Command (12 bytes):**
```
[0-1]   0x8001          tag
[2-5]   0x0000000C      commandSize = 12
[6-9]   0x0000017B      commandCode
[10-11] N               bytesRequested (max 32)
```
**Response (10 + 2 + N bytes):**
```
[0-1]   0x8001
[2-5]   commandSize
[6-9]   0x00000000      RC_SUCCESS
[10-11] N               outputSize
[12..]  random bytes
```

---

### TPM2_PCR_Extend — 0x0182
Extends PCR[n] with a 32-byte measurement digest.
New PCR value = SHA256( PCR_old || measurement ).

**Command (52 bytes):**
```
[0-1]   0x8001
[2-5]   0x00000034      commandSize = 52
[6-9]   0x00000182
[10-13] PCR handle      only bits [1:0] used (PCR 0-3)
[14-17] 0x00000001      count = 1
[18-19] 0x000B          algID = SHA-256
[20-51] measurement     32-byte digest
```
**Response (10 bytes):** header only, RC_SUCCESS.

---

### TPM2_PCR_Read — 0x017E
Returns the current 32-byte value of a PCR.

**Command (14 bytes):**
```
[0-9]   header
[10-13] PCR handle      bits [1:0] = PCR index (0-3)
```
**Response (42 bytes):**
```
[0-9]   header
[10-41] 32-byte PCR value (big-endian)
```

---

### TPM2_HMAC — 0x015D
Computes HMAC-SHA256 of a 32-byte message under a 32-byte key.

**Command (74 bytes):**
```
[0-9]   header
[10-41] 32-byte key
[42-73] 32-byte message
```
**Response (42 bytes):**
```
[0-9]   header
[10-41] 32-byte HMAC-SHA256 result
```

---

## Project Files

```
micro_tpm_v3/
│
├── config.json                  LibreLane v2 config — run: librelane config.json
├── setup.sh                     Clone sha256 + run iverilog simulation
│
├── rtl/
│   ├── tpm_top.v                Top level (standalone, no Caravel)
│   ├── tpm_spi_slave.v          4-wire SPI slave, byte-stream protocol
│   ├── tpm_cmd_proc.v           Main FSM: parse commands, call engines
│   ├── tpm_sha256_wrap.v        Handshake wrapper around sha256_core
│   ├── tpm_mem.v                256-byte dual-port memory (CMD + RSP)
│   ├── tpm_trng.v               3-cell ring-oscillator TRNG
│   └── tpm_pcr_bank.v           4 × 256-bit PCR registers
│
├── cores/
│   └── sha256/                  git clone secworks/sha256 (setup.sh does this)
│       └── src/rtl/
│           ├── sha256_core.v
│           └── sha256_w_mem.v
│
└── tb/
    └── tpm_tb.v                 SPI-based testbench (all 4 commands)
```

---

## Quick Start

```bash
chmod +x setup.sh
./setup.sh          # clones sha256_core, compiles, runs simulation

gtkwave tpm_tb.vcd  # view waveforms

librelane config.json   # synthesize, P&R, DRC, LVS
```

---

## Area Estimate (SKY130 HD, 50 MHz)

| Block | Estimated area |
|---|---|
| `sha256_core` (secworks) | ~105,000 µm² |
| `tpm_cmd_proc` FSM | ~15,000 µm² |
| `tpm_mem` (256 × 8-bit FF) | ~10,000 µm² |
| `tpm_pcr_bank` (4 × 256-bit FF) | ~5,000 µm² |
| `tpm_spi_slave` | ~3,000 µm² |
| `tpm_trng` (3 ring-osc) | ~2,000 µm² |
| Routing, buffers, PDN | ~20,000 µm² |
| **Total** | **~160,000 µm² ≈ 0.16 mm²** |

Die area in `config.json`: **800 µm × 750 µm = 0.60 mm²** (comfortable margin).

---

## External Dependency

`secworks/sha256` — BSD 2-Clause License
https://github.com/secworks/sha256

---

## Known Phase 1 Limitations

- HMAC key and message are fixed at 32 bytes. Variable length requires
  additional streaming states in `tpm_cmd_proc`.
- NV memory uses flip-flops (volatile). PCRs are lost on power cycle.
- TRNG output has no DRBG conditioning. Add CTR-DRBG for production.
- Only 4 PCR registers (PCR 0-3). Phase 2 can add more if area allows.
# Custom_TPM
