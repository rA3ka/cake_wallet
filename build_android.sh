#!/bin/bash
set -e

WORKDIR=./build_android
DEPSDIR=$WORKDIR/dependencies
CAKE=$WORKDIR/cake_wallet

mkdir -p $DEPSDIR

## Clone cake_wallet repo

if [ ! -d "$CAKE" ]; then
  git clone --recursive https://github.com/rA3ka/cake_wallet $CAKE
  echo "=== Cloning cake_wallet repo ==="
else
  echo "=== cake_wallet repo exists, skipping ==="
fi

## Build libanon.so from anon-android

if [ -f "$DEPSDIR/anon-android/external/lib/arm64-v8a/libanon.so" ]; then
  echo "=== libanon.so already built, skipping ==="
elif [ ! -d "$DEPSDIR/anon-android" ]; then
    git clone --recursive https://github.com/anyone-protocol/anon-android.git $DEPSDIR/anon-android
  else
    cd $DEPSDIR/anon-android
    ./anon-make.sh fetch
    ./anon-make.sh build
fi

## Build libtorch.so wrapper

if [ -f "$DEPSDIR/anon-build/out/arm64-v8a/libtorch.so" ]; then
  echo "=== libtorch.so already built, skipping ==="
else
  mkdir -p $DEPSDIR/anon-build && cd $DEPSDIR/anon-build

  ANON_SRC=$DEPSDIR/anon-android/external/anon
  ln -sf $ANON_SRC/src $ANON_SRC/tor

  mkdir -p torch
  cat > torch/torch.h << 'HEADER'
#ifndef TORCH_LIBRARY_H
#define TORCH_LIBRARY_H
#ifdef __cplusplus
extern "C"
{
#endif
int TOR_start(int argc, char *argv[]);
const char* TOR_version();
#ifdef __cplusplus
}
#endif
#endif
HEADER

  cat > torch/torch.cpp << 'CPPFILE'
#include "torch.h"
#include <iostream>
#if !defined(_WIN32) && !defined(__MINGW32__)
#include <sys/wait.h>
#endif
#include <unistd.h>
#include <signal.h>
#include <thread>
#include <atomic>
#include <cstring>
#ifdef __ANDROID__
#include <android/log.h>
#define LOG_TAG "torch"
#define BUFFER_SIZE 1024*32
static int stdoutToLogcat(const char *buf, int size) {
    __android_log_write(ANDROID_LOG_INFO, LOG_TAG, buf);
    return size;
}
static int stderrToLogcat(const char *buf, int size) {
    __android_log_write(ANDROID_LOG_ERROR, LOG_TAG, buf);
    return size;
}
void redirectStdoutThread(int pipe_stdout[2]) {
    char bufferStdout[BUFFER_SIZE];
    while (true) {
        int read_size = read(pipe_stdout[0], bufferStdout, sizeof(bufferStdout) - 1);
        if (read_size > 0) { bufferStdout[read_size] = '\0'; stdoutToLogcat(bufferStdout, read_size); }
    }
}
void redirectStderrThread(int pipe_stderr[2]) {
    char bufferStderr[BUFFER_SIZE];
    while (true) {
        int read_size = read(pipe_stderr[0], bufferStderr, sizeof(bufferStderr) - 1);
        if (read_size > 0) { bufferStderr[read_size] = '\0'; stderrToLogcat(bufferStderr, read_size); }
    }
}
void setupAndroidLogging() {
    static int pfdStdout[2]; static int pfdStderr[2];
    pipe(pfdStdout); pipe(pfdStderr);
    dup2(pfdStdout[1], STDOUT_FILENO); dup2(pfdStderr[1], STDERR_FILENO);
    std::thread(redirectStdoutThread, pfdStdout).detach();
    std::thread(redirectStderrThread, pfdStderr).detach();
}
#endif
static std::atomic<bool> tor_running{false};
static std::thread tor_thread;
#if !defined(_WIN32) && !defined(__MINGW32__)
void sigchld_handler(int sig) { while (waitpid(-1, NULL, WNOHANG) > 0) {} }
#endif
__attribute__((constructor)) void library_init() {
#ifdef __ANDROID__
    setupAndroidLogging();
#endif
#if !defined(_WIN32) && !defined(__MINGW32__)
    signal(SIGCHLD, sigchld_handler);
#endif
}
#ifdef __cplusplus
extern "C" {
#endif
#ifdef __MINGW32__
#define ADDAPI __declspec(dllexport)
#else
#define ADDAPI __attribute__((__visibility__("default")))
#endif
#include <tor/feature/api/tor_api.h>
void run_tor_in_thread(int argc, char** argv) {
    tor_main_configuration_t* cfg = tor_main_configuration_new();
    if (!cfg) { std::cerr << "torch: Failed to create config\n"; tor_running = false; return; }
    if (tor_main_configuration_set_command_line(cfg, argc, argv) != 0) {
        std::cerr << "torch: Failed to set args\n"; tor_main_configuration_free(cfg); tor_running = false; return;
    }
    std::cout << "torch: Starting in background thread\n";
    int rv = tor_run_main(cfg); tor_main_configuration_free(cfg); tor_running = false;
    if (rv != 0) std::cerr << "torch: Exited with code: " << rv << "\n";
}
extern ADDAPI int TOR_start(int argc, char *argv[]) {
#if defined(__APPLE__) || defined(__MINGW32__)
    if (tor_running.load()) { std::cout << "torch: Already running\n"; return 0; }
    if (tor_thread.joinable()) tor_thread.join();
    char** argv_copy = new char*[argc];
    for (int i = 0; i < argc; i++) { size_t len = strlen(argv[i]) + 1; argv_copy[i] = new char[len]; strcpy(argv_copy[i], argv[i]); }
    tor_running = true;
    tor_thread = std::thread([argc, argv_copy]() {
        run_tor_in_thread(argc, argv_copy);
        for (int i = 0; i < argc; i++) delete[] argv_copy[i]; delete[] argv_copy;
    });
    tor_thread.detach();
    std::cout << "torch: Started in background thread\n"; return 0;
#else
    pid_t pid = fork();
    if (pid == -1) { std::cerr << "torch: Failed to fork\n"; return -1; }
    if (pid == 0) {
        tor_main_configuration_t* cfg = tor_main_configuration_new();
        if (!cfg) _exit(-1);
        if (tor_main_configuration_set_command_line(cfg, argc, argv) != 0) { tor_main_configuration_free(cfg); _exit(-1); }
        int rv = tor_run_main(cfg); tor_main_configuration_free(cfg); _exit(rv);
    }
    std::cout << "torch: Started in background process (PID: " << pid << ")\n"; return 0;
#endif
}
const char* TOR_version() { return tor_api_get_provider_version(); }
#ifdef __cplusplus
}
#endif
CPPFILE

  ANONLIBS=$DEPSDIR/anon-android/external/lib
  mkdir -p libs/arm64-v8a libs/armeabi-v7a libs/x86_64 libs/x86
  cp $ANONLIBS/arm64-v8a/libanon.so libs/arm64-v8a/
  cp $ANONLIBS/armeabi-v7a/libanon.so libs/armeabi-v7a/
  cp $ANONLIBS/x86_64/libanon.so libs/x86_64/
  cp $ANONLIBS/x86/libanon.so libs/x86/

  export NDK=$ANDROID_HOME/ndk/26.1.10909125
  export TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64
  export API=24
  mkdir -p out/arm64-v8a out/armeabi-v7a out/x86_64 out/x86

  TARGETS=(
    "aarch64-linux-android:arm64-v8a"
    "armv7a-linux-androideabi:armeabi-v7a"
    "x86_64-linux-android:x86_64"
    "i686-linux-android:x86"
  )
  for TARGET in "${TARGETS[@]}"; do
    TRIPLE="${TARGET%%:*}"
    ABI="${TARGET##*:}"
    echo "=== Building libtorch.so for $ABI ==="
    $TOOLCHAIN/bin/clang++ \
      --target=${TRIPLE}${API} \
      -shared -fPIC -std=c++17 \
      -DANDROID -D__ANDROID__ \
      -I $ANON_SRC/ \
      -L libs/$ABI/ \
      -o out/$ABI/libtorch.so \
      torch/torch.cpp \
      -lanon -llog -nostdlib++ -lc++_static -lc++abi -lc -lm -ldl
    nm -D out/$ABI/libtorch.so | grep "TOR_start\|TOR_version"
  done
fi

## Copy Anyone libs into cake_wallet for Docker build

# cd $CAKE
mkdir -p anon-build/out anon-build/libs
for ABI in arm64-v8a armeabi-v7a x86_64 x86; do
  mkdir -p anon-build/out/$ABI anon-build/libs/$ABI
  cp $DEPSDIR/anon-build/out/$ABI/libtorch.so anon-build/out/$ABI/
  cp $DEPSDIR/anon-build/libs/$ABI/libanon.so anon-build/libs/$ABI/
done

## Replace Dockerfile.torch (skip Tor build)

# cat > scripts/android/docker/Dockerfile.torch << 'DOCKEREOF'
# ARG BASE_IMAGE

# FROM --platform=linux/amd64 ${BASE_IMAGE} AS build

# COPY scripts/prepare_torch.sh /w/scripts/prepare_torch.sh
# RUN /w/scripts/prepare_torch.sh

# COPY anon-build/out/arm64-v8a/libtorch.so /w/scripts/torch_dart/android/src/main/jniLibs/arm64-v8a/libtorch.so
# COPY anon-build/out/armeabi-v7a/libtorch.so /w/scripts/torch_dart/android/src/main/jniLibs/armeabi-v7a/libtorch.so
# COPY anon-build/out/x86_64/libtorch.so /w/scripts/torch_dart/android/src/main/jniLibs/x86_64/libtorch.so
# COPY anon-build/out/x86/libtorch.so /w/scripts/torch_dart/android/src/main/jniLibs/x86/libtorch.so

# COPY anon-build/libs/arm64-v8a/libanon.so /w/scripts/torch_dart/android/src/main/jniLibs/arm64-v8a/libanon.so
# COPY anon-build/libs/armeabi-v7a/libanon.so /w/scripts/torch_dart/android/src/main/jniLibs/armeabi-v7a/libanon.so
# COPY anon-build/libs/x86_64/libanon.so /w/scripts/torch_dart/android/src/main/jniLibs/x86_64/libanon.so
# COPY anon-build/libs/x86/libanon.so /w/scripts/torch_dart/android/src/main/jniLibs/x86/libanon.so

# FROM --platform=linux/amd64 alpine
# COPY --from=build /w /w
# DOCKEREOF

## 5: Speed up Gradle

# grep -q "org.gradle.parallel" android/gradle.properties || {
#   echo "org.gradle.parallel=true" >> android/gradle.properties
#   echo "org.gradle.workers.max=12" >> android/gradle.properties
#   echo "org.gradle.caching=true" >> android/gradle.properties
# }

## Run Docker build for all native DEPSDIR

cd $CAKE
pushd scripts/android
  docker/build.sh
popd

## Create bitcoin secrets if missing (Cake Wallet repo bug)

source $WORKDIR/.env 2>/dev/null || true

if [ ! -f "cw_bitcoin/lib/.secrets.g.dart" ]; then
  echo "const breezApiKey = \"${BREEZ_API_KEY:-dummy_key}\";" > cw_bitcoin/lib/.secrets.g.dart
fi

## 8: Flutter build (everything inside Docker)

cd $CAKE

docker run \
  -v$(pwd):$(pwd) \
  -v$HOME/.pub-cache-docker:/root/.pub-cache \
  -w $(pwd) -i --rm \
  ghcr.io/cake-tech/cake_wallet:debian13-flutter3.32.0-ndkr28-go1.24.1-ruststablenightly \
  bash -x << 'EOF'
set -x -e
git config --global --add safe.directory '*'
pushd scripts/android
  source ./app_env.sh cakewallet
  ./app_config.sh
popd
pushd android/app
  [[ -f key.jks ]] || keytool -genkey -v -keystore key.jks -keyalg RSA \
    -keysize 2048 -validity 10000 -alias testKey -noprompt \
    -dname "CN=CakeWallet" -storepass hunter1 -keypass hunter1
popd
flutter pub get
./model_generator.sh
dart run tool/generate_android_key_properties.dart keyAlias=testKey storeFile=key.jks storePassword=hunter1 keyPassword=hunter1
dart run tool/generate_localization.dart
dart run tool/generate_new_secrets.dart
flutter build apk --release --target-platform android-arm64
EOF

echo "=== BUILD COMPLETE ==="
ls -lh build/app/outputs/flutter-apk/*.apk
