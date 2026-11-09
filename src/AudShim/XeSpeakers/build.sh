#!/bin/zsh
# Build the XeSpeakers AudioServerPlugIn (HAL driver) without Xcode: zsh tools/XeSpeakers/build.sh
#   -> tools/build/XeSpeakers.driver (x86_64, ad-hoc signed)
# Install (user, sudo): sudo cp -R tools/build/XeSpeakers.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
# Needs AudShim >= 0.8.0 (interface v8: speakers; v9 = AudShim 0.9.0 adds the microphones); without it no device.
set -e
SRC=${0:A:h}
OUT=${0:A:h:h}/build/XeSpeakers.driver
rm -rf $OUT
mkdir -p $OUT/Contents/MacOS $OUT/Contents/Resources
cp $SRC/Info.plist $OUT/Contents/Info.plist
plutil -lint $OUT/Contents/Info.plist >/dev/null
clang -arch x86_64 -O2 -Wall -Wextra -bundle -mmacosx-version-min=11.0 \
  -framework CoreAudio -framework CoreFoundation -framework IOKit \
  $SRC/XeSpeakers.c $SRC/xs_ns.c $SRC/df_ns.c -o $OUT/Contents/MacOS/XeSpeakers
# DeepFilterNet3 (libdf.dylib + modelo, ver tools/deepfilternet/README.md): se estiverem em $DFN_BIN, vao dentro do .driver
DFN_BIN=${DFN_BIN:-$HOME/g15aud/dfn-bin}
if [ -f $DFN_BIN/libdf.dylib ] && [ -f $DFN_BIN/DeepFilterNet3_onnx.tar.gz ]; then
  mkdir -p $OUT/Contents/Frameworks
  cp $DFN_BIN/libdf.dylib $OUT/Contents/Frameworks/
  cp $DFN_BIN/DeepFilterNet3_onnx.tar.gz $OUT/Contents/Resources/
  codesign -f -s - $OUT/Contents/Frameworks/libdf.dylib
else
  echo "AVISO: sem libdf em $DFN_BIN: o .driver usa so o xs_ns"
fi
codesign -f -s - $OUT
echo "built $OUT"
