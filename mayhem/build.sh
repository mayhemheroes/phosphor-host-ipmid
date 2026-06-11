#!/usr/bin/env bash
#
# phosphor-host-ipmid/mayhem/build.sh — build the openbmc host-IPMI daemon's message/parse surface
# as sanitized libFuzzer targets (+ standalone reproducers) and the repo's OWN gtest suite for
# mayhem/test.sh.
#
# Fuzzed surface (three additive harnesses, taken from the upstream OSS-Fuzz integration):
#   * fuzz_payload_unpack — ipmi::message::Payload pack/unpack: the byte/bit (un)marshalling that
#       every inbound IPMI request body and outbound response goes through (fundamental ints, fixed
#       bit-width fields uintN_t, UCSD-Pascal strings, vectors/arrays/spans/bitsets, SecureBuffer,
#       optional, nested Payload, unaligned bit drains, prepend/resize). This is the core IPMI
#       command request-message decoder.
#   * fuzz_fru_area     — ipmi::fru::buildFruAreaData(): builds a binary FRU (Field Replaceable Unit)
#       inventory area (chassis/board/product sections, length-prefixed strings) from D-Bus property
#       maps — the FRU write/area-encode path.
#   * fuzz_sensor_utils — ipmi::getSensorAttributes / scaleIPMIValueFromDouble / getScaledIPMIValue:
#       the sensor reading <-> IPMI linearization (M/B/exponent) math used by the sensor commands.
#
# Why ADDITIVE harnesses instead of the in-tree fuzzers: the repo has none; these come from the
# upstream OSS-Fuzz project (vendor_ccs adalogics). They drive library code directly with NO live
# D-Bus. To dodge openbmc's static-init-order fiasco (phosphor-dbus-interfaces static ctors abort at
# startup), we link against HEADER-ONLY partial_dependency() views of phosphor-logging/sdbusplus and
# provide a no-op lg2 do_log() stub (mayhem/harnesses/lg2_stub.cpp).
#
# Build contract from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/OUT/
# STANDALONE_FUZZ_MAIN. We build with libstdc++ (clang's default on Debian) to match the base image's
# libFuzzer runtime ABI — NOT libc++ (the oss-fuzz base default). Coverage is added with
# -fsanitize=fuzzer-no-link; the libFuzzer runtime is linked only into the fuzz binaries. Output lands
# in /mayhem (= $OUT).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF-3 symbols required for Mayhem triage (clang-19 defaults to DWARF-5); threaded
# AFTER $SANITIZER_FLAGS so it always wins. Empty --build-arg keeps empty (no debug info).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${OUT:=/mayhem}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS OUT

cd "$SRC"
git config --global --add safe.directory "$SRC" 2>/dev/null || true

COV="-fsanitize=fuzzer-no-link"
# Relaxations target ONLY the openbmc dep chain / werror subprojects, never the fuzzed parse logic:
#  -Wno-unknown-warning-option: deps pass -Werror=character-conversion, a name this clang lacks.
#  -Wno-error: phosphor-host-ipmid sets werror=true project-wide; warnings in deps must not fail us.
# $DEBUG_FLAGS comes AFTER $SANITIZER_FLAGS so -gdwarf-3 wins over any -g implicit in sanitizer flags.
CPP_ARGS="-Wno-unknown-warning-option -Wno-error -Wno-error=deprecated-declarations $SANITIZER_FLAGS $COV $DEBUG_FLAGS"
LINK_ARGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

# Copy the additive harnesses + lg2 stub into the repo test dir (where meson expects them).
cp mayhem/harnesses/fuzz_payload_unpack.cpp \
   mayhem/harnesses/fuzz_fru_area.cpp \
   mayhem/harnesses/fuzz_sensor_utils.cpp \
   mayhem/harnesses/lg2_stub.cpp \
   test/

# ── 1) Add a `fuzz_engine` meson option (link flags for the fuzz targets), idempotently. ──────────
grep -q "option('fuzz_engine'" meson.options || cat >> meson.options << 'OPTEOF'

option('fuzz_engine', type: 'string', value: '', description: 'Fuzzing engine flags')
OPTEOF

# Disable transport/serialbridge (needs a systemd pkg-config dep we do not configure for fuzzing).
sed -i "s|subdir('transport/serialbridge')|# subdir('transport/serialbridge')|" meson.build

# ── 2) Append the fuzz-target definitions to test/meson.build (idempotent). Header-only partial
#       deps strip link libs so we do NOT pull phosphor-dbus-interfaces (static-init crash); the lg2
#       stub satisfies the resulting do_log() undefined symbol. ────────────────────────────────────
if ! grep -q 'fuzz_payload_unpack' test/meson.build; then
cat >> test/meson.build << 'MESON_EOF'

# ---- Mayhem fuzz targets (additive) ----
phosphor_logging_headers = phosphor_logging_dep.partial_dependency(
    compile_args: true, includes: true)
sdbusplus_headers = sdbusplus_dep.partial_dependency(
    compile_args: true, includes: true)
# phosphor-logging/elog.hpp pulls the GENERATED header
# xyz/openbmc_project/Logging/Entry/server.hpp (sdbus++ codegen owned by
# phosphor-dbus-interfaces). Take a partial dep with sources:true so the codegen
# custom_targets run (header gets produced) and includes:true so its gen/ dir is on
# the include path — but no link libs (avoids the static-init-order crash we dodge
# everywhere else). Only fuzz_fru_area compiles a source (ipmi_fru_info_area.cpp)
# that includes elog.hpp, so only it needs this.
phosphor_dbus_interfaces_headers = phosphor_dbus_interfaces_dep.partial_dependency(
    compile_args: true, includes: true, sources: true)

executable(
    'fuzz_payload_unpack',
    ['fuzz_payload_unpack.cpp', 'lg2_stub.cpp'],
    include_directories: root_inc,
    implicit_include_directories: false,
    dependencies: [
        boost,
        crypto,
        phosphor_logging_headers,
        sdbusplus_headers,
        libsystemd_dep,
    ],
    link_args: get_option('fuzz_engine').split(),
    install: true,
)

executable(
    'fuzz_fru_area',
    ['fuzz_fru_area.cpp', '../ipmi_fru_info_area.cpp', 'lg2_stub.cpp'],
    include_directories: root_inc,
    implicit_include_directories: false,
    dependencies: [phosphor_logging_headers, phosphor_dbus_interfaces_headers],
    link_args: get_option('fuzz_engine').split(),
    install: true,
)

executable(
    'fuzz_sensor_utils',
    ['fuzz_sensor_utils.cpp', '../dbus-sdr/sensorutils.cpp', 'lg2_stub.cpp'],
    include_directories: root_inc,
    implicit_include_directories: false,
    dependencies: [phosphor_logging_headers],
    link_args: get_option('fuzz_engine').split(),
    install: true,
)
MESON_EOF
fi

# ── 3) Resolve subprojects. Use system boost (libboost-all-dev), not the cmake wrap. ──────────────
rm -f subprojects/boost.wrap
rm -rf subprojects/boost-*
meson subprojects download

# stdplus is required transitively but absent from the wrap set — add it explicitly.
if [ ! -d subprojects/stdplus ]; then
  git clone --depth 1 https://github.com/openbmc/stdplus subprojects/stdplus
fi
cat > subprojects/stdplus.wrap << 'WRAPEOF'
[wrap-git]
url = https://github.com/openbmc/stdplus.git
revision = HEAD

[provide]
stdplus = stdplus_dep
WRAPEOF

# ── 4) Patch clang-19 / c++23 header hygiene in the openbmc subprojects (missing includes, stray std
#       forward-declarations, std::move_only_function not in this libstdc++/clang combo). Idempotent;
#       touches ONLY subproject/system dep headers, never phosphor-host-ipmid's own sources. ────────
fixhdr() {
  local f
  f=subprojects/stdexec/include/stdexec/__detail/__utility.hpp
  [ -f "$f" ] && ! grep -q '#include <new>' "$f" && sed -i '1i#include <new>' "$f" || true
  f=subprojects/stdplus/include/stdplus/function_view.hpp
  [ -f "$f" ] && ! grep -q '#include <concepts>' "$f" && sed -i '1i#include <cstddef>\n#include <concepts>\n#include <type_traits>\n#include <memory>' "$f" || true
  f=subprojects/stdplus/include/stdplus/debug/lifetime.hpp
  [ -f "$f" ] && ! grep -q '#include <cstddef>' "$f" && sed -i '1i#include <cstddef>' "$f" || true
  f=subprojects/stdplus/include/stdplus/hash.hpp
  if [ -f "$f" ] && ! grep -q '#include <functional>' "$f"; then sed -i '1i#include <functional>' "$f"; sed -i '/^namespace std$/,/}/ { /template <class Key>/d; /struct hash;/d; }' "$f"; fi
  f=subprojects/stdplus/include/stdplus/net/addr/ip.hpp
  if [ -f "$f" ] && ! grep -q '#include <format>' "$f"; then sed -i '1i#include <format>' "$f"; sed -i '/template <typename T, typename CharT>/d;/struct formatter;/d' "$f"; fi
  f=subprojects/stdplus/include/stdplus/net/addr/subnet.hpp
  if [ -f "$f" ] && ! grep -q '#include <format>' "$f"; then sed -i '1i#include <format>' "$f"; sed -i '/template <typename T, typename CharT>/d;/struct formatter;/d' "$f"; fi
  f=subprojects/stdplus/include/stdplus/net/addr/ether.hpp
  if [ -f "$f" ] && ! grep -q '#include <format>' "$f"; then sed -i '1i#include <format>' "$f"; sed -i '/template <typename T, typename CharT>/d;/struct formatter;/d' "$f"; fi
  f=subprojects/stdplus/include/stdplus/numeric/endian.hpp
  if [ -f "$f" ] && ! grep -q '#include <format>' "$f"; then sed -i '1i#include <format>' "$f"; sed -i '/template <typename T, typename CharT>/d;/struct formatter;/d' "$f"; fi
  f=subprojects/stdplus/include/stdplus/str/cat.hpp
  [ -f "$f" ] && ! grep -q '#include <algorithm>' "$f" && sed -i '1i#include <algorithm>' "$f" || true
  f=subprojects/sdbusplus/include/sdbusplus/asio/connection.hpp
  [ -f "$f" ] && sed -i 's/std::move_only_function/std::function/g' "$f" || true
  f=subprojects/sdbusplus/include/sdbusplus/event.hpp
  [ -f "$f" ] && ! grep -q '#include <unistd.h>' "$f" && sed -i '1i#include <unistd.h>' "$f" || true
  f=subprojects/sdbusplus/src/async/barrier.cpp
  [ -f "$f" ] && ! grep -q '#include <algorithm>' "$f" && sed -i '1i#include <algorithm>' "$f" || true
  # sdbusplus static-init-order fiasco: the generated event registrations (event.cpp.mako) call
  # register_event() from static constructors, which touch the file-scope `static unordered_map
  # event_hooks` in exception.cpp. When a registration ctor runs before event_hooks' own ctor (UB
  # across TUs), emplace() hits a zero-bucket map -> hash % 0 div-by-zero. Under our halting
  # sanitizers that aborts the `message` gtest oracle (and would crash any binary linking these
  # registrations on first use). Fix at the ROOT: turn event_hooks into a Meyers singleton
  # (function-local static, constructed on first use) so it always exists before any register_event.
  # Idempotent (re-applying is a no-op once the definition block is gone). Touches only the
  # downloaded sdbusplus subproject — never phosphor-host-ipmid's own sources.
  f=subprojects/sdbusplus/src/exception.cpp
  if [ -f "$f" ]; then python3 - "$f" <<'PYEH' || true
import re,sys
f=sys.argv[1]; s=open(f).read()
defn=("static std::unordered_map<std::string, sdbusplus::sdbuspp::register_hook>\n"
      "    event_hooks = {};")
if defn in s:
    repl=("static std::unordered_map<std::string, sdbusplus::sdbuspp::register_hook>&\n"
          "    event_hooks()\n{\n"
          "    static std::unordered_map<std::string, sdbusplus::sdbuspp::register_hook>\n"
          "        m;\n    return m;\n}")
    s=s.replace(defn,repl,1)
    s=re.sub(r'event_hooks(?!\()', 'event_hooks()', s)  # bare uses -> accessor call
    open(f,"w").write(s)
PYEH
  fi
  # boost container_hash: std::unary_function removed in C++17.
  find /usr/include/boost -name hash.hpp -path '*/container_hash/*' -exec \
    sed -i 's/struct hash_base : std::unary_function<T, std::size_t>/struct hash_base/' {} + 2>/dev/null || true
}
fixhdr

# ── 5) Configure + build (instrumented). default_library=static so we link archives; -Dtests=enabled
#       so the repo's gtest unit binaries are also built (for mayhem/test.sh). -Dstdplus:gtest=disabled
#       keeps stdplus from pulling googletest as an instrumented shared lib that fails to link the
#       sanitizer runtime. ─────────────────────────────────────────────────────────────────────────
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"
COMMON_OPTS=(
  -Dtests=enabled
  -Dsoftoff=disabled
  -Dipmi-whitelist=disabled
  -Dlibuserlayer=disabled
  -Ddefault_library=static
  -Dstdplus:gtest=disabled
  -Dfuzz_engine="$LIB_FUZZING_ENGINE"
  -Dcpp_args="$CPP_ARGS"
  -Dc_args="$SANITIZER_FLAGS $DEBUG_FLAGS"
  -Dcpp_link_args="$LINK_ARGS"
)
meson setup "$BUILD" "${COMMON_OPTS[@]}" || { fixhdr; meson setup --reconfigure "$BUILD" "${COMMON_OPTS[@]}"; }
# stdexec/extra subprojects can arrive during configure; re-apply header fixes before building.
fixhdr

# Build the fuzz targets and the gtest test suite binaries (for mayhem/test.sh).
ninja -C "$BUILD" -v -j"$MAYHEM_JOBS" \
  test/fuzz_payload_unpack test/fuzz_fru_area test/fuzz_sensor_utils \
  test/message test/session_closesession

# ── 6) Stage the libFuzzer targets to $OUT. ───────────────────────────────────────────────────────
for t in fuzz_payload_unpack fuzz_fru_area fuzz_sensor_utils; do
  cp "$BUILD/test/$t" "$OUT/$t"
  echo "built $t (libFuzzer)"
done

# ── 7) Standalone run-once reproducers (no libFuzzer runtime; read one input file). Non-fatal. ────
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"
# Recover the exact compile flags meson used for each harness so the standalone link matches.
standalone() {
  local target="$1" src="$2"; shift 2
  local extra_obj=("$@")
  local incflags
  incflags="$(python3 - "$BUILD" "$target" <<'PY'
import json,sys,shlex
b,target=sys.argv[1],sys.argv[2]
db=json.load(open(b+"/compile_commands.json"))
ent=next((e for e in db if e.get("file","").endswith(target+".cpp")), None)
if not ent:
    print(""); sys.exit(0)
toks=shlex.split(ent.get("command") or " ".join(ent.get("arguments",[]))); out=[]; i=0
while i<len(toks):
    t=toks[i]
    if t.startswith("-I"):
        out.append(t if len(t)>2 else t+toks[i+1])
        if len(t)==2: i+=1
    elif t=="-isystem":
        out.append(t+toks[i+1]); i+=1
    elif t.startswith("-isystem") or t.startswith("-D") or t=="-std=c++23" or t.startswith("-std="):
        out.append(t)
    i+=1
print(" ".join(out))
PY
)"
  set +e
  $CXX -std=c++23 $SANITIZER_FLAGS $DEBUG_FLAGS $incflags \
      "$SRC/test/$target.cpp" "${extra_obj[@]}" "$SRC/test/lg2_stub.cpp" \
      "$BUILD/standalone_main.o" \
      $(pkg-config --libs libsystemd 2>/dev/null) -lcrypto -lpthread \
      -o "$OUT/$target-standalone"
  [ "$?" -eq 0 ] && echo "built $target-standalone" \
                 || echo "WARNING: $target-standalone link failed (non-fatal); libFuzzer target stands" >&2
  set -e
}
standalone fuzz_payload_unpack ""
standalone fuzz_fru_area "$SRC/ipmi_fru_info_area.cpp"
standalone fuzz_sensor_utils "$SRC/dbus-sdr/sensorutils.cpp"

echo "build.sh complete:"
ls -la "$OUT"/fuzz_payload_unpack "$OUT"/fuzz_fru_area "$OUT"/fuzz_sensor_utils 2>&1 || true
