#!/usr/bin/env bash
# Unit tests: the audio closure, the sensible-audio-check diagnostic, and the
# installer helper that records its findings for the completion summary.
TEST_NAME="audio_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/hardware.sh"

CHECK="${REPO_ROOT}/live/config/includes.chroot/usr/local/bin/sensible-audio-check"
TMP="$(mktemp -d /tmp/sensible-audio-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

t_section "audio closure names what PipeWire does not pull in by itself"
for pkg in alsa-ucm-conf alsa-utils alsa-topology-conf; do
    assert_file_contains "target closure bakes ${pkg}" \
        "${REPO_ROOT}/live/config/package-lists/sensible-target.list.chroot" "${pkg}"
done
for pkg in firmware-cirrus firmware-intel-sound firmware-sof-signed; do
    assert_file_contains "live and target firmware set names ${pkg}" \
        "${REPO_ROOT}/live/config/package-lists/live.list.chroot" "${pkg}"
done
hardware_source="$(<"${INSTALLER_DIR}/lib/hardware.sh")"
for pkg in alsa-ucm-conf alsa-utils firmware-cirrus firmware-intel-sound; do
    assert_contains "installer package set keeps ${pkg}" "${hardware_source}" $'\n        '"${pkg}"$'\n'
done
target_list="$(<"${REPO_ROOT}/live/config/package-lists/sensible-target.list.chroot")"
audio_block="${target_list%%# Apps — default set*}"
assert_contains "ALSA packages sit in the hardware block, not the documented app set" "${audio_block}" $'\nalsa-ucm-conf\n'
assert_contains "installer removes live mixer state from the target" \
    "$(<"${INSTALLER_DIR}/sensible-install.sh")" 'rm -f "${MNT}/var/lib/alsa/asound.state"'
assert_contains "installer records live audio findings before the summary" \
    "$(<"${INSTALLER_DIR}/sensible-install.sh")" $'\n    record_audio_warnings\n'

# --- sensible-audio-check fixtures ------------------------------------------
# A Lenovo Legion 7 15ASH11: Realtek ALC287 (marketed as ALC3306), codec
# subsystem 17aa:395b, two Cirrus CS35L56 amplifiers behind ACPI CSC3556.
make_sysroot() {
    local root="${TMP}/$1"
    rm -rf "$root"
    mkdir -p "$root/proc/asound/card0" "$root/proc/asound/card1" \
        "$root/sys/bus/acpi/devices/CSC3556:00" "$root/sys/bus/acpi/devices/PNP0C0A:00" \
        "$root/sys/class/dmi/id" "$root/usr/share/alsa/ucm2" \
        "$root/usr/lib/firmware/cirrus" "$root/usr/lib/firmware/intel/sof" "$root/usr/sbin"
    printf 'LENOVO\n' > "$root/sys/class/dmi/id/sys_vendor"
    printf '83V9\n' > "$root/sys/class/dmi/id/product_name"
    printf 'Legion 7 15ASH11\n' > "$root/sys/class/dmi/id/product_version"
    cat > "$root/proc/asound/cards" <<'EOF'
 0 [Generic        ]: HDA-Intel - HD-Audio Generic
                      HD-Audio Generic at 0xb0548000 irq 161
 1 [Generic_1      ]: HDA-Intel - HD-Audio Generic
                      HD-Audio Generic at 0xb0540000 irq 162
EOF
    printf 'Codec: ATI R6xx HDMI\nAddress: 0\nVendor Id: 0x1002aa01\nSubsystem Id: 0x00aa0100\n' \
        > "$root/proc/asound/card0/codec#0"
    printf 'Codec: Realtek ALC287\nAddress: 0\nVendor Id: 0x10ec0287\nSubsystem Id: 0x17aa395b\n' \
        > "$root/proc/asound/card1/codec#0"
    printf '#!/bin/sh\n' > "$root/usr/sbin/alsactl"
    chmod +x "$root/usr/sbin/alsactl"
    local tuning
    for tuning in cs35l56-b0-dsp1-misc-17aa395b.wmfw cs35l56-b0-dsp1-misc-17aa395b-amp1.bin \
        cs35l56-b0-dsp1-misc-17aa395b-amp2.bin; do
        printf 'fixture\n' > "$root/usr/lib/firmware/cirrus/${tuning}"
    done
    printf '%s' "$root"
}

BOUND_LOG="${TMP}/bound.log"
cat > "$BOUND_LOG" <<'EOF'
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: Cirrus Logic CS35L56 Rev B0 OTP3 fw:3.4.4 (patched=0)
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: DSP system name: '17AA395B', amp name: 'AMP1'
snd_hda_codec_alc269 hdaudioC1D0: ALC287: picked fixup  for codec SSID 17aa:395b
snd_hda_codec_alc269 hdaudioC1D0: Found 2 CSC3556 on i2c (-%s:00-cs35l56-hda.%d)
snd_hda_codec_alc269 hdaudioC1D0: bound i2c-CSC3556:00-cs35l56-hda.0 (ops cs35l56_hda_comp_ops [snd_hda_scodec_cs35l56])
snd_hda_codec_alc269 hdaudioC1D0: bound i2c-CSC3556:00-cs35l56-hda.1 (ops cs35l56_hda_comp_ops [snd_hda_scodec_cs35l56])
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: Calibration applied
EOF
UNBOUND_LOG="${TMP}/unbound.log"
cat > "$UNBOUND_LOG" <<'EOF'
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: Cirrus Logic CS35L56 Rev B0 OTP3 fw:3.4.4 (patched=0)
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: DSP system name: '17AA395B', amp name: 'AMP1'
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.1: Cirrus Logic CS35L56 Rev B0 OTP3 fw:3.4.4 (patched=0)
snd_hda_codec_alc269 hdaudioC1D0: autoconfig for ALC287: line_outs=2 (0x14/0x17/0x0/0x0/0x0) type:speaker
EOF
# What Debian stable, or Testing before firmware-nonfree 20260519-1, logs on
# this laptop: the amplifiers probe, then refuse to run without their tuning.
TUNING_LOG="${TMP}/tuning.log"
cat > "$TUNING_LOG" <<'EOF'
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: Cirrus Logic CS35L56 Rev B0 OTP3 fw:3.4.4 (patched=0)
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: DSP system name: '17AA395B', amp name: 'AMP1'
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.1: DSP system name: '17AA395B', amp name: 'AMP2'
snd_hda_codec_alc269 hdaudioC1D0: Found 2 CSC3556 on i2c (-%s:00-cs35l56-hda.%d)
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: .bin file required but not found
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.1: .bin file required but not found
EOF
FIRMWARE_LOG="${TMP}/firmware.log"
cat > "$FIRMWARE_LOG" <<'EOF'
snd_hda_codec_alc269 hdaudioC1D0: bound i2c-CSC3556:00-cs35l56-hda.0 (ops cs35l56_hda_comp_ops [snd_hda_scodec_cs35l56])
cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: Direct firmware load for cirrus/cs35l41-dsp1-spk-prot-17aa3855.wmfw failed with error -2
cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: Direct firmware load for cirrus/cs35l41-dsp1-spk-prot-17aa3855.wmfw failed with error -2
sof-audio-pci-intel-tgl 0000:00:1f.3: Direct firmware load for intel/sof/sof-tgl.ri failed with error -2
sof-audio-pci-intel-tgl 0000:00:1f.3: error: failed to load DSP firmware -2
snd_sof_amd_rembrandt 0000:c3:00.5: Direct firmware load for amd/sof/sof-rmb.ri failed with error -2
amdgpu 0000:c3:00.0: Direct firmware load for amdgpu/psp_14_0_0_toc.bin failed with error -2
EOF
MUTED_MIXER="${TMP}/muted-mixer.txt"
cat > "$MUTED_MIXER" <<'EOF'
Simple mixer control 'Master',0
  Capabilities: pvolume pvolume-joined pswitch pswitch-joined
  Mono: Playback 65 [75%] [-16.50dB] [off]
Simple mixer control 'Headphone',0
  Front Left: Playback [off]
  Front Right: Playback [off]
Simple mixer control 'Speaker',0
  Front Left: Playback [off]
  Front Right: Playback [off]
Simple mixer control 'Capture',0
  Front Left: Capture 63 [100%] [30.00dB] [on]
EOF
OPEN_MIXER="${TMP}/open-mixer.txt"
cat > "$OPEN_MIXER" <<'EOF'
Simple mixer control 'Master',0
  Mono: Playback 65 [75%] [-16.50dB] [on]
Simple mixer control 'Headphone',0
  Front Left: Playback [off]
  Front Right: Playback [off]
Simple mixer control 'Speaker',0
  Front Left: Playback [on]
  Front Right: Playback [on]
EOF

# The diagnostic runs as a separate bash process, so its external commands are
# doubled by exported functions; every call lands in the shared mock log.
mock_setup
export MOCK_LOG
journalctl() { mlog "journalctl $*"; [ -n "${MOCK_KERNEL_LOG:-}" ] && cat "${MOCK_KERNEL_LOG}"; return 0; }
dmesg() { mlog "dmesg"; return 1; }
wpctl() {
    mlog "wpctl $*"
    case "$*" in
        "get-volume @DEFAULT_AUDIO_SINK@")
            [ "${MOCK_NO_SINK:-0}" != 1 ] || return 1
            printf '%s\n' "${MOCK_SINK_VOLUME:-Volume: 0.52}" ;;
        "get-volume @DEFAULT_AUDIO_SOURCE@") printf 'Volume: 1.00\n' ;;
    esac
    return 0
}
amixer() {
    mlog "amixer $*"
    case "$*" in
        -q*) : ;;
        *) cat "${MOCK_AMIXER:-$OPEN_MIXER}" ;;
    esac
}
systemctl() { mlog "systemctl $*"; printf '%s\n%s\n' "${MOCK_PIPEWIRE:-active}" "${MOCK_WIREPLUMBER:-active}"; }
export -f mlog journalctl dmesg wpctl amixer systemctl
export MOCK_KERNEL_LOG="$BOUND_LOG" MOCK_AMIXER="$OPEN_MIXER" MOCK_SINK_VOLUME="Volume: 0.52"
export MOCK_NO_SINK=0 MOCK_PIPEWIRE=active MOCK_WIREPLUMBER=active
XDG_RUNTIME_DIR="/run/user/1000"
export XDG_RUNTIME_DIR

run_check() { # sysroot args...
    local root="$1"
    shift
    mock_reset
    OUTPUT="$(SENSIBLE_AUDIO_SYSROOT="$root" bash "$CHECK" "$@" 2>&1)"
    RC=$?
}

t_section "usage"
run_check "$(make_sysroot usage)" --bogus
assert_rc "unknown argument is a usage error" 2 "$RC"
assert_contains "usage error names the argument" "$OUTPUT" "unknown argument '--bogus'"
run_check "$(make_sysroot usage)" --help
assert_rc "help exits cleanly" 0 "$RC"
assert_contains "help prints usage" "$OUTPUT" "Usage: sensible-audio-check [--summary] [--unmute]"

t_section "healthy Legion 7 15ASH11: amplifiers bound, nothing muted"
ROOT="$(make_sysroot healthy)"
run_check "$ROOT"
assert_rc "no problem reported" 0 "$RC"
assert_contains "machine identified from DMI" "$OUTPUT" "Machine: LENOVO 83V9 (Legion 7 15ASH11)"
assert_contains "sound cards listed" "$OUTPUT" "card1: HDA-Intel - HD-Audio Generic"
assert_contains "Realtek codec and subsystem shown for bug reports" "$OUTPUT" "Codec:   Realtek ALC287 (subsystem 0x17aa395b)"
assert_contains "amplifier ACPI device listed" "$OUTPUT" "Speaker amplifiers (ACPI): CSC3556"
assert_contains "per-model amplifier tuning reported present" "$OUTPUT" "Amplifier tuning: cirrus/cs35l56-*-dsp1-misc-17aa395b* present"
assert_not_contains "unrelated ACPI devices are not amplifiers" "$OUTPUT" "PNP0C0A"
assert_contains "default output state shown" "$OUTPUT" "Default output: Volume: 0.52"
assert_not_contains "no PROBLEM block" "$OUTPUT" "PROBLEM:"
assert_contains "clean result" "$OUTPUT" "Result: no audio problems detected."
assert_contains "kernel log read from the journal" "$(cat "$MOCK_LOG")" "journalctl -k -b 0 --no-pager -o cat"
assert_contains "ALSA mixer inspected per card" "$(cat "$MOCK_LOG")" "amixer -c 1"
run_check "$ROOT" --summary
assert_rc "summary agrees" 0 "$RC"
assert_eq "summary prints nothing when healthy" "" "$OUTPUT"

t_section "amplifier present in ACPI but never bound: the missing-kernel-quirk case"
MOCK_KERNEL_LOG="$UNBOUND_LOG" run_check "$ROOT"
assert_rc "unbound amplifier is a problem" 1 "$RC"
assert_contains "problem names amplifier, codec and subsystem" "$OUTPUT" \
    "PROBLEM: Speaker amplifier CSC3556 was not bound by this kernel (Realtek ALC287, subsystem 0x17aa395b); internal speakers may stay silent until a newer kernel is installed."
assert_contains "fix is a kernel update" "$OUTPUT" "sudo apt update && sudo apt full-upgrade"
assert_contains "headphones expectation explained" "$OUTPUT" "Headphones usually still work."
assert_contains "count reported" "$OUTPUT" "Result: 1 problem(s) found."
MOCK_KERNEL_LOG="$UNBOUND_LOG" run_check "$ROOT" --summary
assert_rc "summary exit code matches" 1 "$RC"
assert_eq "summary is exactly one plain line" \
    "Speaker amplifier CSC3556 was not bound by this kernel (Realtek ALC287, subsystem 0x17aa395b); internal speakers may stay silent until a newer kernel is installed." \
    "$OUTPUT"

t_section "amplifier tuning missing from the installed firmware snapshot: the Debian stable case"
TUNING_ROOT="$(make_sysroot tuning)"
rm -f "$TUNING_ROOT"/usr/lib/firmware/cirrus/cs35l56-b0-dsp1-misc-17aa395b*
MOCK_KERNEL_LOG="$TUNING_LOG" run_check "$TUNING_ROOT"
assert_rc "missing tuning is a problem" 1 "$RC"
assert_contains "problem names the file pattern and the package" "$OUTPUT" \
    "PROBLEM: Amplifier tuning firmware for this laptop (cirrus/cs35l56-*-dsp1-misc-17aa395b*) is not installed; the CS35L56 speaker amplifiers stay silent without it."
assert_contains "cause is the firmware snapshot, fix is a firmware update" "$OUTPUT" "The installed firmware-cirrus snapshot predates this laptop"
assert_contains "upstream fallback named" "$OUTPUT" "https://gitlab.com/kernel-firmware/linux-firmware"
assert_not_contains "no kernel-quirk blame while the tuning is missing" "$OUTPUT" "was not bound by this kernel"
assert_contains "driver refusal quoted for the report" "$OUTPUT" "cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: .bin file required but not found"
MOCK_KERNEL_LOG="$TUNING_LOG" run_check "$TUNING_ROOT" --summary
assert_eq "tuning problem leads the summary" \
    "Amplifier tuning firmware for this laptop (cirrus/cs35l56-*-dsp1-misc-17aa395b*) is not installed; the CS35L56 speaker amplifiers stay silent without it." \
    "$(head -n 1 <<< "$OUTPUT")"
MOCK_KERNEL_LOG="" run_check "$TUNING_ROOT"
assert_rc "detected from the codec subsystem ID when the log is unreadable" 1 "$RC"
assert_contains "system name falls back to the codec subsystem ID" "$OUTPUT" "cirrus/cs35l56-*-dsp1-misc-17aa395b*) is not installed"
printf 'fixture\n' > "$TUNING_ROOT/usr/lib/firmware/cirrus/cs35l56-b0-dsp1-misc-17aa395b-amp1.bin.zst"
MOCK_KERNEL_LOG="$BOUND_LOG" run_check "$TUNING_ROOT"
assert_rc "compressed firmware counts as installed" 0 "$RC"
assert_not_contains "no tuning problem with a compressed file" "$OUTPUT" "PROBLEM: Amplifier tuning"

t_section "CS35L41 laptop without per-model tuning runs generic: a note, not a problem"
L41_ROOT="$(make_sysroot cs35l41)"
rmdir "$L41_ROOT/sys/bus/acpi/devices/CSC3556:00"
mkdir -p "$L41_ROOT/sys/bus/acpi/devices/CSC3551:00"
L41_LOG="${TMP}/cs35l41.log"
printf '%s\n' \
    "cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: DSP system name: '17AA3855', amp name: 'AMP1'" \
    "snd_hda_codec_alc269 hdaudioC1D0: bound i2c-CSC3551:00-cs35l41-hda.0 (ops cs35l41_hda_comp_ops [snd_hda_scodec_cs35l41])" \
    > "$L41_LOG"
MOCK_KERNEL_LOG="$L41_LOG" run_check "$L41_ROOT"
assert_rc "generic CS35L41 operation is not a problem" 0 "$RC"
assert_contains "note explains the reduced mode" "$OUTPUT" "- No per-model CS35L41 tuning (cirrus/cs35l41-dsp1-spk-prot-17aa3855*) is installed"
assert_not_contains "CS35L56 tuning is not demanded from a CS35L41 board" "$OUTPUT" "cs35l56-*-dsp1-misc"

t_section "SoundWire-style board: amplifier ACPI device without an HDA Realtek codec is not flagged"
SDW_ROOT="$(make_sysroot soundwire)"
rm -f "$SDW_ROOT/proc/asound/card1/codec#0"
MOCK_KERNEL_LOG="$UNBOUND_LOG" run_check "$SDW_ROOT"
assert_rc "no HDA codec means no binding expectation" 0 "$RC"
assert_not_contains "no false amplifier problem" "$OUTPUT" "was not bound"

t_section "unreadable kernel log degrades to a note, not a false problem"
MOCK_KERNEL_LOG="" run_check "$ROOT"
assert_rc "no problem without evidence" 0 "$RC"
assert_contains "falls back to dmesg" "$(cat "$MOCK_LOG")" "dmesg"
assert_contains "explains how to get driver detail" "$OUTPUT" "run 'sudo sensible-audio-check' for driver and firmware detail"
assert_contains "amplifier binding left unverified" "$OUTPUT" "Could not verify that the CSC3556 speaker amplifier is bound"

t_section "missing firmware files map to the Debian package that ships them"
MOCK_KERNEL_LOG="$FIRMWARE_LOG" run_check "$ROOT"
assert_rc "missing firmware is a problem" 1 "$RC"
assert_contains "Cirrus file maps to firmware-cirrus" "$OUTPUT" \
    "cirrus/cs35l41-dsp1-spk-prot-17aa3855.wmfw was not found; it belongs to Debian's firmware-cirrus package."
assert_contains "reinstall command given" "$OUTPUT" "sudo apt install --reinstall firmware-cirrus"
assert_eq "duplicate kernel lines are reported once" 1 "$(grep -c 'cs35l41-dsp1-spk-prot-17aa3855.wmfw was not found' <<< "$OUTPUT")"
assert_contains "Intel SOF file maps to firmware-sof-signed" "$OUTPUT" \
    "intel/sof/sof-tgl.ri was not found; it belongs to Debian's firmware-sof-signed package."
assert_contains "AMD SOF firmware is explained as unpackaged" "$OUTPUT" \
    "amd/sof/sof-rmb.ri was not found; Debian does not package the AMD SOF DSP firmware."
assert_not_contains "graphics firmware is not an audio problem" "$OUTPUT" "amdgpu/psp_14_0_0_toc.bin"
assert_contains "driver errors are quoted for bug reports" "$OUTPUT" "PROBLEM: The audio driver reported errors in the kernel log"
assert_contains "the SOF error line is included" "$OUTPUT" "sof-audio-pci-intel-tgl 0000:00:1f.3: error: failed to load DSP firmware -2"

t_section "no sound card at all"
NOCARD_ROOT="$(make_sysroot nocard)"
: > "$NOCARD_ROOT/proc/asound/cards"
rm -f "$NOCARD_ROOT/proc/asound/card0/codec#0" "$NOCARD_ROOT/proc/asound/card1/codec#0"
run_check "$NOCARD_ROOT"
assert_rc "missing card is a problem" 1 "$RC"
assert_contains "no cards stated" "$OUTPUT" "Sound cards: none"
assert_contains "problem explains DSP firmware and firmware setup" "$OUTPUT" "PROBLEM: No sound card was detected by the kernel."
assert_contains "Intel legacy-driver workaround documented" "$OUTPUT" "snd_intel_dspcfg.dsp_driver=1"
assert_not_contains "no amplifier claim without a codec" "$OUTPUT" "was not bound"

t_section "missing userspace pieces"
UCM_ROOT="$(make_sysroot ucm)"
rmdir "$UCM_ROOT/usr/share/alsa/ucm2"
rm -f "$UCM_ROOT/usr/sbin/alsactl"
# The fixture ships the per-model tuning inside cirrus/, so remove the tree.
rm -rf "$UCM_ROOT/usr/lib/firmware/cirrus"
rmdir "$UCM_ROOT/usr/lib/firmware/intel/sof"
run_check "$UCM_ROOT"
assert_rc "missing UCM profiles are a problem" 1 "$RC"
assert_contains "UCM problem names the package" "$OUTPUT" "ALSA Use Case Manager profiles are missing (alsa-ucm-conf)"
assert_contains "UCM fix command" "$OUTPUT" "sudo apt install alsa-ucm-conf"
assert_contains "Cirrus firmware package missing with an amplifier present" "$OUTPUT" "PROBLEM: Cirrus amplifier firmware is not installed (firmware-cirrus)."
assert_contains "missing package also means missing tuning" "$OUTPUT" "PROBLEM: Amplifier tuning firmware for this laptop"
assert_contains "alsa-utils absence is a note" "$OUTPUT" "- alsa-utils (alsamixer, alsactl, speaker-test) is not installed"
assert_contains "Intel SOF directory absence is a note" "$OUTPUT" "- Intel SOF firmware directory is absent (firmware-sof-signed)"

t_section "PipeWire session state"
MOCK_SINK_VOLUME="Volume: 0.52 [MUTED]" run_check "$ROOT"
assert_rc "muted output is a problem" 1 "$RC"
assert_contains "mute named" "$OUTPUT" "PROBLEM: The default audio output is muted in PipeWire."
assert_contains "unmute hint" "$OUTPUT" "sensible-audio-check --unmute"
MOCK_SINK_VOLUME="Volume: 0.00" run_check "$ROOT"
assert_rc "zero volume is a problem" 1 "$RC"
assert_contains "zero volume named" "$OUTPUT" "PROBLEM: The default audio output volume is 0."
MOCK_NO_SINK=1 run_check "$ROOT"
assert_rc "no sink is a problem" 1 "$RC"
assert_contains "no sink named" "$OUTPUT" "PROBLEM: PipeWire has no default audio output device."
MOCK_WIREPLUMBER=inactive run_check "$ROOT"
assert_rc "stopped session manager is a problem" 1 "$RC"
assert_contains "unit and state named" "$OUTPUT" "PROBLEM: PipeWire session service wireplumber is not running (inactive)."
assert_contains "start command given" "$OUTPUT" "systemctl --user start wireplumber"
XDG_RUNTIME_DIR="" run_check "$ROOT"
assert_rc "no session is not a problem" 0 "$RC"
assert_not_contains "no session commands without a user session" "$(cat "$MOCK_LOG")" "wpctl"
assert_contains "skipped session checks are explained" "$OUTPUT" "PipeWire session checks were skipped"

t_section "ALSA mixer mute detection ignores the auto-muted headphone switch"
MOCK_AMIXER="$MUTED_MIXER" run_check "$ROOT"
assert_rc "muted speaker controls are a problem" 1 "$RC"
assert_contains "muted controls listed per card" "$OUTPUT" "PROBLEM: ALSA mixer controls are muted: 0:Master 0:Speaker 1:Master 1:Speaker (card:control)."
assert_not_contains "headphone auto-mute is not reported" "$OUTPUT" "Headphone"

t_section "--unmute repairs the session and the mixer, and nothing else"
MOCK_AMIXER="$MUTED_MIXER" MOCK_SINK_VOLUME="Volume: 0.00 [MUTED]" run_check "$ROOT" --unmute
assert_contains "PipeWire output unmuted" "$(cat "$MOCK_LOG")" "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0"
assert_contains "zero volume raised to a safe level" "$(cat "$MOCK_LOG")" "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.5"
assert_contains "speaker control unmuted on the Realtek card" "$(cat "$MOCK_LOG")" "amixer -q -c 1 sset Speaker unmute"
assert_contains "master control unmuted" "$(cat "$MOCK_LOG")" "amixer -q -c 1 sset Master unmute"
assert_not_contains "headphone switch left to auto-mute" "$(cat "$MOCK_LOG")" "sset Headphone"
assert_contains "user told to re-check" "$OUTPUT" "Re-run sensible-audio-check to confirm."
MOCK_SINK_VOLUME="Volume: 0.52" run_check "$ROOT" --unmute
assert_not_contains "volume is not changed when it is not zero" "$(cat "$MOCK_LOG")" "wpctl set-volume"
assert_not_contains "no mixer writes when nothing is muted" "$(cat "$MOCK_LOG")" "amixer -q"
run_check "$ROOT"
assert_not_contains "plain run never writes to PipeWire" "$(cat "$MOCK_LOG")" "wpctl set-"
assert_not_contains "plain run never writes to the mixer" "$(cat "$MOCK_LOG")" "amixer -q"

unset -f journalctl dmesg wpctl amixer systemctl
mock_teardown

t_section "installer records live-session audio findings as warnings"
mock_setup
FAKE_CHECK="${TMP}/audio-check"
cat > "$FAKE_CHECK" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MOCK_LOG}"
printf 'Speaker amplifier CSC3556 was not bound by this kernel (Realtek ALC287, subsystem 0x17aa395b); internal speakers may stay silent until a newer kernel is installed.\n'
printf '\n'
printf 'ALSA Use Case Manager profiles are missing (alsa-ucm-conf); SOF and SoundWire laptops show no usable audio devices without them.\n'
exit 1
EOF
chmod +x "$FAKE_CHECK"
INSTALL_WARNINGS=()
SENSIBLE_AUDIO_CHECK="$FAKE_CHECK" record_audio_warnings 2>/dev/null
assert_rc "helper never fails the install" 0 $?
assert_eq "one warning per finding, blank lines dropped" 2 "${#INSTALL_WARNINGS[@]}"
assert_eq "warning is prefixed and verbatim" \
    "Audio: Speaker amplifier CSC3556 was not bound by this kernel (Realtek ALC287, subsystem 0x17aa395b); internal speakers may stay silent until a newer kernel is installed." \
    "${INSTALL_WARNINGS[0]}"
assert_contains "checker is asked for the machine-readable summary" "$(cat "$MOCK_LOG")" "--summary"
INSTALL_WARNINGS=()
SENSIBLE_AUDIO_CHECK="${TMP}/does-not-exist" record_audio_warnings 2>/dev/null
assert_rc "missing checker is skipped" 0 $?
assert_eq "missing checker records nothing" 0 "${#INSTALL_WARNINGS[@]}"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CHECK"
INSTALL_WARNINGS=()
SENSIBLE_AUDIO_CHECK="$FAKE_CHECK" record_audio_warnings 2>/dev/null
assert_eq "healthy live session records nothing" 0 "${#INSTALL_WARNINGS[@]}"
mock_teardown

t_summary
