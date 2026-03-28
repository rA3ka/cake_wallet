#!/bin/bash
set -e

WORKDIR=$(pwd)/build
DEPSDIR=$WORKDIR/dependencies
CAKE=$WORKDIR/cake_wallet

if [ ! -f "$WORKDIR/.env" ]; then
  echo "ERROR: $WORKDIR/.env not found. See $WORKDIR/.env-example"
  exit 1
fi

source $WORKDIR/.env

mkdir -p $DEPSDIR

## Clone cake_wallet repo

if [ ! -d "$CAKE" ]; then
  echo -e "\n=== Cloning cake_wallet repo ===\n"
  git clone --recursive https://github.com/rA3ka/cake_wallet $CAKE
else
  cd $CAKE
  git fetch origin
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse origin/$BRANCH)
  if [ "$LOCAL" != "$REMOTE" ]; then
    echo -e "\n=== Updating cake_wallet repo ===\n"
    git pull origin $BRANCH
    git submodule update --init --recursive
  else
    echo -e "\n=== cake_wallet repo up to date, skipping ===\n"
  fi
  cd -
fi

## Clone anon-android repo

if [ ! -d "$DEPSDIR/anon-android" ]; then
  echo -e "\n=== Cloning anon-android ===\n"
  git clone --recursive https://github.com/anyone-protocol/anon-android.git $DEPSDIR/anon-android
else
  cd $DEPSDIR/anon-android
  git fetch origin
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse origin/$BRANCH)
  if [ "$LOCAL" != "$REMOTE" ]; then
    echo -e "\n=== Updating anon-android ===\n"
    git pull origin $BRANCH
    git submodule update --init --recursive
  else
    echo -e "\n=== anon-android up to date, skipping ===\n"
  fi
  cd -
fi

## Build libtorch.so wrapper (Docker)

if [ -f "$DEPSDIR/anon-build/out/arm64-v8a/libtorch.so" ]; then
  echo -e "\n=== Anyone libs already built, skipping ===\n"
else
  echo -e "\n=== Building libanon.so and libtorch.so inside Docker ===\n"
  mkdir -p $DEPSDIR/anon-build
  docker run --platform linux/amd64 \
    -v$DEPSDIR:$DEPSDIR \
    -w $DEPSDIR -i --rm \
    ghcr.io/cake-tech/cake_wallet:debian13-flutter3.32.0-ndkr28-go1.24.1-ruststablenightly \
    bash << 'DEOF'
set -x -e
 
apt-get update && apt-get install -y autopoint gettext po4a autoconf automake libtool

export ANDROID_HOME=/opt/android-sdk-linux
export NDK=$(ls -d $ANDROID_HOME/ndk/*/ | head -1)
export TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64
export ANDROID_NDK_HOME=$NDK
export API=24
DEPS=$(pwd)

# Build libanon.so
cd anon-android
./anon-make.sh fetch
./anon-make.sh build -a "arm64-v8a armeabi-v7a x86_64"
cd $DEPS

# Build libtorch.so
cd anon-build

ANON_SRC=$DEPS/anon-android/external/anon
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

ANONLIBS=$DEPS/anon-android/external/lib
mkdir -p libs/arm64-v8a libs/armeabi-v7a libs/x86_64
cp $ANONLIBS/arm64-v8a/libanon.so libs/arm64-v8a/
cp $ANONLIBS/armeabi-v7a/libanon.so libs/armeabi-v7a/
cp $ANONLIBS/x86_64/libanon.so libs/x86_64/

mkdir -p out/arm64-v8a out/armeabi-v7a out/x86_64

for TARGET in "aarch64-linux-android:arm64-v8a" "armv7a-linux-androideabi:armeabi-v7a" "x86_64-linux-android:x86_64"; do
  TRIPLE="${TARGET%%:*}"
  ABI="${TARGET##*:}"
  echo -e "\n=== Building libtorch.so for $ABI ===\n"
  $TOOLCHAIN/bin/clang++ \
    --target=${TRIPLE}${API} \
    -shared -fPIC -std=c++17 \
    -DANDROID -D__ANDROID__ \
    -I $ANON_SRC/ \
    -L libs/$ABI/ \
    -o out/$ABI/libtorch.so \
    -Wl,-z,max-page-size=16384 \
    torch/torch.cpp \
    -lanon -llog -nostdlib++ -lc++_static -lc++abi -lc -lm -ldl
  nm -D out/$ABI/libtorch.so | grep "TOR_start\|TOR_version"
done

echo -e "\n=== Anyone libs built ===\n"
DEOF
fi

## Copy Anyone libs into cake_wallet for Docker build

cd $CAKE
mkdir -p anon-build/out anon-build/libs
for ABI in arm64-v8a armeabi-v7a x86_64; do
  mkdir -p anon-build/out/$ABI anon-build/libs/$ABI
  cp $DEPSDIR/anon-build/out/$ABI/libtorch.so anon-build/out/$ABI/
  cp $DEPSDIR/anon-build/libs/$ABI/libanon.so anon-build/libs/$ABI/
done

## Run Docker build for all native DEPSDIR

cd $CAKE
pushd scripts/android
  docker/build.sh
popd

## Create bitcoin secrets if missing (Cake Wallet repo bug?)

if [ ! -f "cw_bitcoin/lib/.secrets.g.dart" ]; then
  echo "const breezApiKey = \"${BREEZ_API_KEY:-dummy_key}\";" > cw_bitcoin/lib/.secrets.g.dart
fi

## 8: Flutter build (everything inside Docker)

cd $CAKE

docker run \
  -v$(pwd):$(pwd) \
  -v$WORKDIR/.pub-cache:/root/.pub-cache \
  -e KEY_STORE_PASSWORD="$KEY_STORE_PASSWORD" \
  -e CN_NAME="$CN_NAME" \
  -e ORG_NAME="$ORG_NAME" \
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
  [[ -f key.jks ]] || keytool -v \
    -genkey \
    -keystore key.jks \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -alias testKey \
    -noprompt \
    -dname "CN=$CN_NAME, O=$ORG_NAME" \
    -storepass "$KEY_STORE_PASSWORD" \
    -keypass "$KEY_STORE_PASSWORD"
popd
flutter pub get
./model_generator.sh
dart run tool/generate_android_key_properties.dart \
  keyAlias=testKey \
  storeFile=key.jks \
  storePassword="$KEY_STORE_PASSWORD" \
  keyPassword="$KEY_STORE_PASSWORD" \
dart run tool/generate_localization.dart
dart run tool/generate_new_secrets.dart
flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64,android-arm
EOF

echo -e "\n=== BUILD COMPLETE ===\n"
ls -lh build/app/outputs/flutter-apk/*.apk
