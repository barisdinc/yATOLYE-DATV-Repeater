# yATOLYE DATV Repeater

A stand-alone DATV (digital amateur television) repeater built on the
[ADALM-PLUTO](https://wiki.analog.com/university/tools/pluto) SDR.

The repeater receives a DATV signal in the 2.4 GHz band and retransmits it,
unchanged, in the 5.8 GHz band. The receive and transmit frequencies, channel
bandwidth, receiver gain and AGC mode, and transmit power are all set from a
configuration file. The RX-to-TX relay runs entirely in the FPGA, so no
samples pass through the ARM CPU and latency stays at a few clock cycles.

The repeater can also transmit its own **DVB-S2 beacon** in the lower part
of the output channel, next to the relayed signal. The beacon plays a
transport stream file in a loop (QPSK, 333 kS/s, 500 kS/s, 1 MS/s or any
other symbol rate). The DVB-S2 encoder runs on the ARM, and the FPGA shifts
the signal to its place in the channel.

This repository contains no firmware sources. It holds a set of patches for
the official [Analog Devices PlutoSDR firmware](https://github.com/analogdevicesinc/plutosdr-fw)
(release `v0.38`), plus a script that downloads that firmware and applies
the patches.

## yDATV-Repeater in action

[![yDATV-Repeater in action](https://i.ytimg.com/vi/p3D83u95pEU/maxresdefault.jpg)](https://youtu.be/p3D83u95pEU)

▶️ **[Watch on YouTube: AdalmPluto yATOLYE DATV Repeater Project](https://youtu.be/p3D83u95pEU)**

> **Note:** Transmitting at 5.65–5.85 GHz requires an amateur radio licence
> and is subject to your national band plan. The AD9363 on the Pluto is only
> specified up to 3.8 GHz. At 5.8 GHz it works in AD9364 mode, but the output
> power is low and varies between units. Use a suitable band-pass filter and
> power amplifier on the output.

---

## Architecture

### System overview

```mermaid
flowchart LR
    ANT_RX(("RX antenna<br/>2.4 GHz"))
    ANT_TX(("TX antenna<br/>5.8 GHz"))

    subgraph PLUTO["ADALM-PLUTO"]
        direction LR
        subgraph AD936X["AD936x RF transceiver (FDD)"]
            direction TB
            RXLO["RX LO<br/>2300–2450 MHz"]
            RXCH["RX chain<br/>LNA · AGC · analog LPF<br/>ADC · decim. FIR"]
            TXCH["TX chain<br/>interp. FIR · DAC<br/>analog LPF · attenuator"]
            TXLO["TX LO<br/>5650–5850 MHz"]
        end

        subgraph FPGA["Zynq-7010 programmable logic"]
            direction TB
            ADC_IF["axi_ad9361<br/>RX interface"]
            XPDR["axi_datv_xpdr<br/>gain · saturation<br/>power detector · squelch"]
            INTERP["TX DMA ·<br/>8× interpolator"]
            NCO["beacon NCO<br/>(frequency shift)"]
            SUM(("+"))
            DAC_IF["axi_ad9361<br/>TX interface"]
            DMA["RX DMA<br/>(libiio, iiod)"]
        end

        subgraph PS["Zynq ARM / Linux"]
            direction TB
            CONF[/"/etc/datv.conf<br/>/mnt/jffs2/datv.conf"/]
            SCRIPT["datv_repeater<br/>(S60datv at boot)"]
            TS[/"beacon .ts file"/]
            FFMPEG["ffmpeg<br/>(loop, constant rate TS)"]
            DVBS2["dvbs2_tx<br/>DVB-S2 QPSK + RRC"]
        end
    end

    ANT_RX --> RXCH
    RXLO -.-> RXCH
    RXCH -- "12-bit I/Q" --> ADC_IF
    ADC_IF -- "I0/Q0" --> XPDR
    ADC_IF --> DMA
    XPDR --> SUM
    TS --> FFMPEG --> DVBS2 -- "I/Q, fs/8" --> INTERP
    INTERP --> NCO --> SUM
    SUM --> DAC_IF
    DAC_IF -- "12-bit I/Q" --> TXCH
    TXLO -.-> TXCH
    TXCH --> ANT_TX

    CONF --> SCRIPT
    SCRIPT -- "iio: LO, BW, gain,<br/>AGC, attenuation" --> AD936X
    SCRIPT -- "AXI-Lite<br/>0x7C450000" --> XPDR
    SCRIPT -.-> FFMPEG
```

The frequency translation from 2.4 GHz to 5.8 GHz happens in the AD936x
itself. Its RX and TX local oscillators are separate synthesizers, so the
receiver can be tuned to the input channel and the transmitter to the output
channel at the same time (FDD mode). RX and TX share one baseband sample
clock. This lets the received I/Q samples be sent straight to the
transmitter without resampling or clock domain crossing.

### FPGA data path

```
                      axi_ad9361 (l_clk domain)
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  │ adc_data_i0/q0 ──┬─► rx_fir_decimator ─► cpack ─► RX DMA ─► libiio       │
  │ (12-bit, sign-   │                                                       │
  │  extended to 16) │   ┌──────────────── axi_datv_xpdr ─────────────────┐  │
  │                  │   │                                                │  │
  │                  └──►│ s0: capture ─► s1: x·gain (Q4.12) ─► s2: >>8,  │  │
  │                      │                    I²+Q²             saturate  │  │
  │                      │                     │                    │     │  │
  │                      │                     ▼                    ▼     │  │
  │                      │            IIR power avg (2^n) ─► squelch/mute │  │
  │                      │                     │              (hang time) │  │
  │                      │                     ▼                    │     │  │
  │                      │                 POWER reg                ▼     │  │
  │                      │                              repeater (enable) │  │
  │                      │                                          │     │  │
  │ TX DMA ─► upack ─► tx_fir_interpolator ─┬─► NCO: x·e^(jφ) ─►(+)◄┘     │  │
  │ (beacon, fs/8)       (8×)               │   sin table (BRAM)  │       │  │
  │                      │                  │   4 DSP mixer   saturate    │  │
  │                      │                  │   (beacon enable)   │       │  │
  │                      │                  └─► bypass (both off) ┤       │  │
  │                      └────────────────────────────────────────┼───────┘  │
  │                                                               ▼          │
  │                        dac_data_i0/q0 (DAC data select = 2) ◄─┘          │
  └──────────────────────────────────────────────────────────────────────────┘
```

$\color{green}\textbf{When the repeater and the beacon are both disabled, the TX path gets the}$
$\color{green}\textbf{normal DMA/interpolator data, so the Pluto behaves like a stock unit.}$

When the **repeater** is enabled, the TX gets the processed RX samples. When the
**beacon** is enabled, the DMA/interpolator data is multiplied by
e^(j·2π·f·n/fs) (frequency shift by `BEACON_FREQ`) and added to the repeater
output with saturation. The squelch and the force mute act on the repeater
path only, so the beacon stays on when there is no input signal.

The NCO uses a quarter wave sine table in block RAM, addressed with the 12
MSBs of a 32-bit phase accumulator (spurs below −72 dBc, about the level of
the 12-bit DAC), and a complex mixer on 4 DSP slices. The frequency shift
has to happen after the interpolator: its pass band is only ±0.4 × fs/8, so
the DMA data cannot carry a signal at the edge of a 10 MHz channel.

Control registers cross from the AXI clock domain to the data clock domain
through `up_xfer_cntrl`, and status registers cross back through
`up_xfer_status`.

### Software

| Component | Location on target | Function |
| --- | --- | --- |
| `datv_repeater` | `/usr/sbin/datv_repeater` | Reads the configuration, validates it, programs the AD936x through libiio and the FPGA core through `/dev/mem`, and runs the beacon. Supports `start`, `stop`, `restart`, `status`. |
| `datv_beacon` | `/usr/sbin/datv_beacon` | Starts and stops the beacon from the command line (`start [file] [kS/s] [fec]`, `stop`, `status`), without changing the persistent configuration. |
| `dvbs2_tx` | `/usr/bin/dvbs2_tx` | DVB-S2 QPSK modulator: TS in, RRC shaped I/Q out to the TX DMA (libiio). |
| `ffmpeg` | `/usr/bin/ffmpeg` | Plays the beacon file in a loop and remuxes it to a constant rate TS (`-c copy`, no re-encoding). |
| `atolye_beacon.ts` | `/usr/share/datv/atolye_beacon.ts` | Default beacon video. |
| `S60datv` | `/etc/init.d/S60datv` | Starts the repeater at boot. |
| `datv.conf` | `/etc/datv.conf` | Default configuration, part of the firmware image (read-only). |
| user configuration | `/mnt/jffs2/datv.conf` | Optional persistent override, survives reboots and firmware updates. |

---

## Technical specifications

| Parameter | Value |
| --- | --- |
| Hardware | ADALM-PLUTO Rev.C (Xilinx Zynq-7010 + AD9363), operated in AD9364 mode |
| Base firmware | plutosdr-fw `v0.38` (Linux 5.15, Buildroot 2022.02, Vivado 2022.2) |
| Duplex mode | FDD, 1 RX / 1 TX (RX1A in, TX1A out) |
| Input (RX) frequency | 2300 – 2450 MHz, default 2400 MHz |
| Output (TX) frequency | 5650 – 5850 MHz, default 5760 MHz |
| Channel bandwidth | 0.2 – 20 MHz, default 10 MHz (RX and TX analog filters) |
| Baseband sample rate | 2.5 – 61.44 MSPS; auto = 1.25 × bandwidth (12.5 MSPS for 10 MHz); with the beacon on, rounded up to a multiple of 8 × symbol rate (13.33 MSPS for 333 kS/s, 16 MSPS for 500 kS/s and 1 MS/s) |
| RX gain control | `manual`, `slow_attack`, `fast_attack`, `hybrid` |
| RX manual gain | −3 … 71 dB, 1 dB steps |
| TX power control | Attenuation 0 … 89.75 dB, 0.25 dB steps (0 dB = maximum output) |
| Digital gain (FPGA) | −40 … +24 dB, 0.1 dB resolution (unsigned Q4.12, 0x1000 = 0 dB) |
| Squelch threshold | −90 … 0 dBFS (0 dBFS = full-scale complex sinusoid) |
| Squelch hang time | 0 … 60 000 ms |
| Power detector | I²+Q² of the 12-bit samples, 1-pole IIR, time constant 2^n samples (n = 0 … 24) |
| FPGA core latency | 5 data clock cycles (RX sample to TX sample) |
| Beacon | DVB-S2 CCM, single TS stream, QPSK, code rates 1/4 … 9/10, normal or short frames, pilots on/off, roll-off 0.35 / 0.25 / 0.20 |
| Beacon symbol rate | 25 – 4000 kS/s (fs/8 must be an integer multiple ≥ 2), e.g. 333 kS/s 2/3 = 440 kbit/s, 500 kS/s 3/4 = 744 kbit/s, 1 MS/s 2/3 = 1322 kbit/s |
| Beacon frequency | Default −3 MHz from the TX LO (5757.000 MHz in the default 5760 MHz / 10 MHz channel), any offset, or auto: lower edge of the beacon at the lower edge of the channel (5755.338 MHz for 500 kS/s) |
| Beacon NCO | 32-bit phase, 12-bit sine table, spurs < −72 dBc |
| Beacon CPU load | `dvbs2_tx`: ~9 % of one core at 333 kS/s, ~11 % at 1 MS/s; `ffmpeg` remux: < 5 % |
| FPGA core address | `0x7C450000` (64 KiB AXI-Lite window) |
| Timing (full design) | All constraints met, WNS +0.877 ns, WHS +0.008 ns |
| Resources (full design) | 13 194 LUT (75 %), 22 986 FF (65 %), 80 DSP48 (100 %), 2.5 BRAM |

### FPGA core register map (`axi_datv_xpdr`)

| Offset | Name | Access | Description |
| --- | --- | --- | --- |
| `0x000` | VERSION | RO | Core version, `0x00010161` = 1.1.a |
| `0x004` | ID | RO | Instance ID |
| `0x008` | SCRATCH | RW | Scratch register |
| `0x00C` | MAGIC | RO | `0x44415456` ("DATV") |
| `0x040` | CONTROL | RW | bit 0: enable (TX fed from RX), bit 1: squelch enable, bit 2: force mute, bit 3: beacon enable |
| `0x044` | GAIN | RW | [15:0] digital gain, unsigned Q4.12, `0x1000` = 0 dB (ADC full scale → DAC full scale) |
| `0x048` | SQ_THRESH | RW | [23:0] squelch open threshold, compared to POWER |
| `0x04C` | SQ_HANG | RW | [31:0] squelch hang time in samples |
| `0x050` | AVG_SHIFT | RW | [4:0] power averaging, time constant 2^n samples (max 24) |
| `0x054` | BEACON_FREQ | RW | [31:0] beacon NCO phase increment, signed, f = fs · n / 2³² |
| `0x080` | STATUS | RO | bit 0: enabled, bit 1: squelch open (TX active), bit 2: beacon enabled |
| `0x084` | POWER | RO | [23:0] averaged I²+Q²; full-scale complex sinusoid = 4 194 304 |
| `0x088` | SAT_COUNT | RO | Number of saturated output samples (wraps): repeater gain, beacon mixer and the sum |

---

## Configuration

The repeater reads `/etc/datv.conf` first, then `/mnt/jffs2/datv.conf` and
`/var/run/datv.conf` if they exist. Later files take precedence.
`/var/run/datv.conf` is in RAM and is written by `datv_beacon`. To
customise persistently:

```sh
ssh root@192.168.2.1                    # password: analog
cp /etc/datv.conf /mnt/jffs2/datv.conf
vi /mnt/jffs2/datv.conf
datv_repeater restart                   # apply without reboot
```

| Key | Default | Range | Description |
| --- | --- | --- | --- |
| `enable` | `1` | 0, 1 | 1 = relay RX to TX, 0 = TX muted |
| `rx_freq_mhz` | `2400` | 2300 – 2450 | Input centre frequency |
| `tx_freq_mhz` | `5760` | 5650 – 5850 | Output centre frequency |
| `bandwidth_mhz` | `10` | 0.2 – 20 | Channel bandwidth |
| `sample_rate_msps` | `0` | 0 – 61.44 | 0 = auto (1.25 × bandwidth, min 2.5) |
| `rx_gain_mode` | `slow_attack` | manual, slow_attack, fast_attack, hybrid | RX AGC mode |
| `rx_gain_db` | `40` | −3 – 71 | RX gain, `manual` mode only |
| `tx_attenuation_db` | `10` | 0 – 89.75 | TX attenuation, 0 = maximum power |
| `digital_gain_db` | `0` | −40 – 24 | FPGA gain between RX and TX |
| `squelch` | `0` | 0, 1 | Mute TX when no input signal |
| `squelch_dbfs` | `−40` | −90 – 0 | Squelch threshold |
| `squelch_hang_ms` | `500` | 0 – 60000 | Keep TX on after the signal drops |
| `power_avg_shift` | `10` | 0 – 24 | Power detector time constant 2^n samples |
| `beacon` | `1` | 0, 1 | DVB-S2 beacon on/off (works with `enable = 0` too: beacon only) |
| `beacon_file` | `/usr/share/datv/atolye_beacon.ts` | path | Transport stream (or any file ffmpeg can remux to TS), played in a loop |
| `beacon_sr_ksps` | `500` | 25 – 4000 | Symbol rate; integers ending in 3 or 6 mean the 1/3 values (333 = 333.333 kS/s) |
| `beacon_fec` | `2/3` | 1/4 … 9/10 | QPSK code rate |
| `beacon_rolloff` | `0.35` | 0.35, 0.25, 0.20 | RRC roll-off |
| `beacon_pilots` | `0` | 0, 1 | DVB-S2 pilots |
| `beacon_level_dbfs` | `−15` | −60 – −3 | Beacon RMS level relative to DAC full scale (peaks ~6 dB higher) |
| `beacon_offset_khz` | `-3000` | auto, ±30000 | Beacon centre relative to `tx_freq_mhz`; auto = lower channel edge |
| `beacon_name` | `yATOLYE-BEACON` | no spaces | DVB service name |

The script checks every value before applying anything. If a value is out
of range, it stops with an error and the TX stays muted. While the device
is being reconfigured, the TX is muted and set to maximum attenuation.

### Status

```
# datv_repeater status
RX LO:        2399999998 Hz
TX LO:        5759999996 Hz
sample rate:  15999999 Hz
RX bandwidth: 10000000 Hz
RX gain:      slow_attack, 71.000000 dB
RX RSSI:      118.75 dB
TX gain:      -10.000000 dB
repeater:     enabled
TX output:    active
input power:  -36.6 dBFS
saturations:  0
beacon:       5757.000 MHz, offset -3000000 Hz, running
beacon file:  /usr/share/datv/atolye_beacon.ts
dvbs2_tx:     -s 500000.000 -o 2000000.000 -f 2/3 -r 0.35  -l -15, mux 654514 bit/s
```

### Beacon

```sh
datv_beacon start                          # default file, 500 kS/s, QPSK 2/3
datv_beacon start /tmp/my.ts 500 3/4       # own file, 500 kS/s, QPSK 3/4
datv_beacon start "" 1000                  # default file, 1 MS/s
datv_beacon stop
```

`datv_beacon` writes the settings to `/var/run/datv.conf` and restarts the
repeater, so the change is lost at the next reboot. The beacon is on by
default; to switch it off permanently, set `beacon = 0` in
`/mnt/jffs2/datv.conf` (the other `beacon_*` keys can be overridden there
too). Copy your own files to `/tmp` (RAM) or to a USB
stick; `/mnt/jffs2` is less than 1 MB.

The chain on the ARM is:

```
ffmpeg -re -stream_loop -1 -i FILE -c copy -f mpegts -muxrate 0.99×TS_RATE
  | dvbs2_tx -s SYMRATE -o FS/8 -f FEC -l LEVEL     (libiio, TX DMA)
```

ffmpeg does not re-encode, so the file has to fit into the channel: its
total bit rate must be below the TS rate of the selected symbol rate and
FEC. The script warns in the log if it does not, and `dvbs2_tx` reports
dropped packets in `/var/log/datv_beacon.log`. The Pluto CPU is too slow to
encode H.264 in real time, so prepare the file on a PC, for example for
333 kS/s QPSK 2/3 (440 kbit/s):

```sh
ffmpeg -i input.mp4 -vf "scale=640:360,fps=25" \
  -c:v libx264 -preset slow -profile:v main -b:v 280k -maxrate 280k -bufsize 280k \
  -x264-params "nal-hrd=cbr:keyint=25:min-keyint=25:scenecut=0" \
  -c:a aac -b:a 48k -ac 1 -f mpegts beacon.ts
```

`dvbs2_tx` inserts null packets when ffmpeg is slower than the channel. Its
output is bit exact with the GNU Radio gr-dtv DVB-S2 transmitter for all
QPSK code rates and frame sizes. On the hardware, the beacon was captured
through the TX→RX leakage of the AD936x and decoded with leandvb.

The relayed signal and the beacon add up in the FPGA. With the RX AGC on,
the relayed signal sits at about −12 dBFS, so with the beacon on, a lower
`digital_gain_db` (e.g. −3 … −6 dB) or `beacon_level_dbfs` leaves more
headroom. Watch the `saturations` counter in `datv_repeater status`.

### Notes on the squelch

When AGC is enabled, the level seen by the FPGA is normalised by the AGC,
so `squelch_dbfs` is a threshold relative to the AGC working point, not an
absolute input level. Short bursts from other users of the 2.4 GHz ISM band
(Wi-Fi, Bluetooth) can briefly push the average above the threshold and
open the squelch. Increase `power_avg_shift` and/or use manual RX gain to
make it more selective.

---

## Building

### Requirements

- Linux host (tested on Ubuntu 24.04)
- Xilinx Vivado / Vitis **2022.2** installed under `/opt/Xilinx`
- The usual Buildroot host packages (`build-essential`, `git`, `bc`,
  `cpio`, `rsync`, `unzip`, `wget`, `python3`, …), `dfu-util`, `sshpass`
- About 40 GB of free disk space

### Get the sources

```sh
git clone https://github.com/barisdinc/yATOLYE-DATV-Repeater.git
cd yATOLYE-DATV-Repeater
./setup.sh            # or ./setup.sh --shallow for a smaller download
```

`setup.sh`:

1. clones `analogdevicesinc/plutosdr-fw` at tag `v0.38` into `./plutosdr-fw`
2. checks out the `hdl`, `buildroot`, `linux` and `u-boot-xlnx` submodules
   and makes sure they are at the commits the patches are based on
3. creates a `yatolye-datv` branch in `hdl` and `buildroot` and applies the
   patches from `patches/` with `git am`

You can safely run the script again. It skips patches that are already
applied, and it refuses to touch a submodule that has local changes.

### Build

```sh
cd plutosdr-fw
SKIP_LEGAL=1 make build/pluto.dfu
```

The first build takes about an hour: toolchain, root filesystem, Linux and
the Vivado implementation.

> Pass `SKIP_LEGAL` (and any other option) as an **environment variable**,
> not as a `make` argument. Variables given on the `make` command line are
> passed on to the HDL build. The HDL build then puts the Vivado project in
> a separate sub-directory, and the top-level Makefile picks up the old
> bitstream instead.

### Load and test from RAM

This does not touch the flash. A power cycle brings back the previous
firmware.

```sh
ssh root@192.168.2.1 device_reboot ram
dfu-util -D build/pluto.dfu -a firmware.dfu
dfu-util -d 0456:b674 -a firmware.dfu -e
```

### Write to flash

```sh
ssh root@192.168.2.1 device_reboot sf
dfu-util -D build/pluto.dfu -a firmware.dfu
dfu-util -d 0456:b674 -a firmware.dfu -e
```

### AD9364 mode

Tuning the TX to 5.8 GHz requires the AD9364 frequency range. Enable it once
on the device:

```sh
fw_setenv attr_name compatible
fw_setenv attr_val ad9364
reboot
```

---

## Repository layout

```
.
├── README.md
├── setup.sh                     # clone plutosdr-fw v0.38 and apply the patches
└── patches
    ├── hdl
    │   ├── 0001-library-Add-axi_datv_xpdr-DATV-transponder-core.patch
    │   ├── 0002-projects-pluto-Insert-axi_datv_xpdr-between-RX-and-T.patch
    │   ├── 0003-library-axi_datv_xpdr-Add-an-NCO-shifted-beacon-path.patch
    │   └── 0004-projects-pluto-Clock-the-axi_datv_xpdr-beacon-NCO-wi.patch
    └── buildroot
        ├── 0001-package-ad936x_ref_cal-libiio-Update-hashes-of-git-t.patch
        ├── 0002-configs-zynq_pluto-Rebrand-as-yATOLYE-DATV-Repeater-.patch
        ├── 0003-board-pluto-Replace-motd-with-the-yATOLYE-DATV-Repea.patch
        ├── 0004-board-pluto-Add-DATV-repeater-control-script-and-con.patch
        ├── 0005-package-dvbs2-tx-New-package.patch
        └── 0006-board-pluto-Add-a-DVB-S2-beacon-to-the-DATV-repeater.patch
```

| Patch | Description |
| --- | --- |
| hdl 0001 | New `axi_datv_xpdr` IP core (gain, saturation, power detector, squelch) |
| hdl 0002 | Pluto block design: core inserted between the RX and TX paths at `0x7C450000` |
| hdl 0003 | Beacon path in `axi_datv_xpdr`: NCO (BRAM sine table + 4 DSP mixer) and saturating adder |
| hdl 0004 | Pluto block design: DAC valid connected to the beacon NCO |
| buildroot 0001 | Updated hashes for the git-generated `ad936x_ref_cal` and `libiio` tarballs |
| buildroot 0002 | Hostname `atolye-datv-repeater`, login banner, `ffmpeg` and `lame` packages |
| buildroot 0003 | yATOLYE DATV Repeater login banner (`/etc/motd`) |
| buildroot 0004 | `datv_repeater` control script, `datv.conf` and `S60datv` init script |
| buildroot 0005 | New `dvbs2-tx` package (DVB-S2 QPSK modulator, GPL-3.0-or-later, LDPC tables from GNU Radio gr-dtv) |
| buildroot 0006 | Beacon support in `datv_repeater`, `datv_beacon` command, default beacon file |

## Known limitations

- The AD9363 is not specified above 3.8 GHz. Output power at 5.8 GHz is
  low and varies from unit to unit, so an external PA is required.
- TX power is set as attenuation, not as an absolute level in dBm. An
  absolute setting would need a per-unit calibration table.
- When the squelch mutes the output, the DAC sends zeros, but some TX LO
  leakage remains at the output frequency. Use `enable = 0` (maximum
  attenuation) to switch the transmitter off completely.
- The full design uses all 80 DSP slices and about 75 % of the LUTs of the
  Zynq-7010, which leaves little room for more processing in the FPGA.
- The beacon shares the channel with the relayed signal. A signal received
  at the same place in the 2.4 GHz input channel (3 MHz below the RX LO by
  default) is relayed on top of the beacon.
- Starting or stopping the beacon restarts the repeater (the sample rate
  may change), which interrupts the relayed signal for about a second.
- The beacon only re-muxes its file (`-c copy`); live video or re-encoding
  on the Pluto is not supported.
