#!/bin/bash

set -eux -o pipefail
shopt -s failglob

ZUUL_JOB_NAME=$(jq < ~/zuul-env.json -r '.job')
ZUUL_PROJECT_SRC_DIR=$HOME/$(jq < ~/zuul-env.json -r '.project.src_dir')
ZUUL_PROJECT_SHORT_NAME=$(jq < ~/zuul-env.json -r '.project.short_name')

# We're reusing our artifacts, so we absolutely need a stable destdir.
PREFIX=~/target
mkdir ${PREFIX}
RUN_TMP=${PREFIX}/run-tmp
mkdir ${RUN_TMP}

CI_PARALLEL_JOBS=$(awk -vcpu=$(getconf _NPROCESSORS_ONLN) 'BEGIN{printf "%.0f", cpu*1.3+1}')
CMAKE_OPTIONS="-DCMAKE_INSTALL_RPATH:INTERNAL=${PREFIX}/lib64 -DCMAKE_INSTALL_RPATH_USE_LINK_PATH:INTERNAL=ON"
CFLAGS=""
CXXFLAGS=""
LDFLAGS=""

if [[ $ZUUL_JOB_NAME =~ .*-clang.* ]]; then
    export CC=clang
    export CXX=clang++
    export LD=clang
    export CXXFLAGS="-stdlib=libc++"
    export LDFLAGS="-stdlib=libc++"
fi

if [[ $ZUUL_JOB_NAME =~ .*-asan-ubsan ]]; then
    export CFLAGS="-fsanitize=address,undefined ${CFLAGS}"
    export CXXFLAGS="-fsanitize=address,undefined ${CXXFLAGS}"
    export LDFLAGS="-fsanitize=address,undefined ${LDFLAGS}"

    # On Fedora 31, libev's ev_realloc looks fishy for sysrepoctl & sysrepocfg
    export LSAN_OPTIONS="suppressions=${ZUUL_PROJECT_SRC_DIR}/ci/lsan.supp:print_suppressions=0"
fi

if [[ $ZUUL_JOB_NAME =~ .*-tsan ]]; then
    export CFLAGS="-fsanitize=thread ${CFLAGS}"
    export CXXFLAGS="-fsanitize=thread ${CXXFLAGS}"
    export LDFLAGS="-fsanitize=thread ${LDFLAGS}"

    # there *are* errors, and I do not want an early exit
    export TSAN_OPTIONS="exitcode=0 log_path=/home/ci/zuul-output/logs/tsan.log"
fi

BUILD_DIR=~/build
mkdir ${BUILD_DIR}
export PATH=${PREFIX}/bin:$PATH
export LD_LIBRARY_PATH=${PREFIX}/lib64:${PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export PKG_CONFIG_PATH=${PREFIX}/lib64/pkgconfig:${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}


build_dep_cmake() {
    mkdir ${BUILD_DIR}/$1
    pushd ${BUILD_DIR}/$1
    cmake -GNinja ${CMAKE_OPTIONS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-Debug} -DCMAKE_INSTALL_PREFIX=${PREFIX} ${ZUUL_PROJECT_SRC_DIR}/$1
    ninja-build install
    popd
}

build_dep_autoconf() {
    pushd ${ZUUL_PROJECT_SRC_DIR}/$1
    shift
    ./configure --prefix=${PREFIX} "$@"
    make -j${CI_PARALLEL_JOBS}
    make install
    popd
}

do_test_dep_cmake() {
    pushd ${BUILD_DIR}/$1
    shift
    ctest --output-on-failure "$@"
    popd
}

emerge_dep() {
    if [[ -f ${ZUUL_PROJECT_SRC_DIR}/$1/CMakeLists.txt ]]; then
        build_dep_cmake "$@"
    elif [[ -f ${ZUUL_PROJECT_SRC_DIR}/$1/configure ]]; then
        build_dep_autoconf "$@"
    else
        echo "Unrecognized buildsystem for $1"
        exit 1
    fi
}

if [[ $ZUUL_JOB_NAME =~ .*-asan.* ]]; then
    CMAKE_OPTIONS="${CMAKE_OPTIONS} -DUSE_SR_MEM_MGMT:BOOL=OFF"
    # https://gitlab.kitware.com/cmake/cmake/issues/16609
    CMAKE_OPTIONS="${CMAKE_OPTIONS} -DTHREADS_HAVE_PTHREAD_ARG:BOOL=ON"
fi

# force-enable tests for packages which use, eh, interesting setup
# - libyang and libnetconf2 copmare CMAKE_BUILD_TYPE to lowercase "debug"...
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DENABLE_BUILD_TESTS=ON -DENABLE_VALGRIND_TESTS=OFF"
# - sysrepo at least defaults to them being active

# nuke python2 builds because we cannot write to the site_path
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DGEN_PYTHON_BINDINGS=OFF"

ARTIFACT=$(git --git-dir ${ZUUL_PROJECT_SRC_DIR}/.git rev-parse HEAD).tar.zst

emerge_dep libredblack --with-pic --without-rbgen

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DGEN_LANGUAGE_BINDINGS=ON -DGEN_PYTHON_BINDINGS=OFF -DGEN_JAVA_BINDINGS=OFF" emerge_dep libyang
do_test_dep_cmake libyang -j${CI_PARALLEL_JOBS}

# sysrepo needs to use a persistent repo location
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DREPOSITORY_LOC=${PREFIX}/etc-sysrepo -DDAEMON_PID_FILE=${RUN_TMP}/sysrepod.pid -DDAEMON_SOCKET=${RUN_TMP}/sysrepod.sock -DPLUGIN_DAEMON_PID_FILE=${RUN_TMP}/sysrepo-plugind.pid -DSUBSCRIPTIONS_SOCKET_DIR=${RUN_TMP}/sysrepo-subscriptions" emerge_dep sysrepo

# These tests are only those which can run on the global repo.
# They also happen to fail when run in parallel. That's expected, they manipulate a shared repository.
do_test_dep_cmake sysrepo
# Now build it once again somewhere else and execute the whole testsuite on them.
mkdir ${BUILD_DIR}/build-sysrepo-tests
pushd ${BUILD_DIR}/build-sysrepo-tests
mkdir ${RUN_TMP}/b-s-t
cmake -GNinja ${CMAKE_OPTIONS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-Debug} -DCMAKE_INSTALL_PREFIX=${PREFIX} \
    -DDAEMON_PID_FILE=${RUN_TMP}/b-s-t/sysrepod.pid -DDAEMON_SOCKET=${RUN_TMP}/b-s-t/sysrepod.sock \
    -DPLUGIN_DAEMON_PID_FILE=${RUN_TMP}/b-s-t/sysrepo-plugind.pid -DSUBSCRIPTIONS_SOCKET_DIR=${RUN_TMP}/b-s-t/sysrepo-subscriptions \
${ZUUL_PROJECT_SRC_DIR}/sysrepo
ninja-build
if [[ $ZUUL_JOB_NAME =~ f32-gcc ]]; then
  # This fails with SIGABRT, and it *could* be due to the use of the io_uring backend within libev.
  # I won't waste my time debugging this on a legacy branch any further.
  # Thread 16 "cm_test" received signal SIGABRT, Aborted.
  #   [Switching to Thread 0x7ffff5a69700 (LWP 12222)]
  #   __GI_raise (sig=sig@entry=6) at ../sysdeps/unix/sysv/linux/raise.c:50
  # 50        return ret;
  # Missing separate debuginfos, use: dnf debuginfo-install libcmocka-1.1.5-3.fc32.x86_64 systemd-libs-245.8-2.fc32.x86_64
  # (gdb) t a a bt
  #
  # Thread 16 (Thread 0x7ffff5a69700 (LWP 12222)):
  # #0  __GI_raise (sig=sig@entry=6) at ../sysdeps/unix/sysv/linux/raise.c:50
  # #1  0x00007ffff7c72895 in __GI_abort () at abort.c:79
  # #2  0x00007ffff7f71604 in iouring_process_cqe (cqe=<optimized out>, cqe=<optimized out>, loop=0x5d0630) at ev_iouring.c:434
  # #3  iouring_handle_cq (loop=0x5d0630) at ev_iouring.c:562
  # #4  0x00007ffff7f75d10 in ev_run (flags=0, loop=0x5d0630) at ev.c:4002
  # #5  ev_run (loop=0x5d0630, flags=0) at ev.c:3878
  # #6  0x0000000000476097 in cm_event_loop (cm_ctx=0x63de90) at /home/ci/src/gerrit.cesnet.cz/CzechLight/dependencies/sysrepo/src/connection_manager.c:1874
  # #7  0x0000000000476188 in cm_event_loop_threaded (cm_ctx_p=0x63de90) at /home/ci/src/gerrit.cesnet.cz/CzechLight/dependencies/sysrepo/src/connection_manager.c:1891
  # #8  0x00007ffff7f8e432 in start_thread (arg=<optimized out>) at pthread_create.c:477
  # #9  0x00007ffff7d4e913 in clone () at ../sysdeps/unix/sysv/linux/x86_64/clone.S:95
  # ...
  ctest --output-on-failure -E cm_test
else
  ctest --output-on-failure
fi
rm -rf ${RUN_TMP}/b-s-t
popd

emerge_dep libnetconf2
# https://github.com/CESNET/libnetconf2/issues/153
do_test_dep_cmake libnetconf2 -j${CI_PARALLEL_JOBS} -E test_io
pushd ${BUILD_DIR}/libnetconf2
ctest --output-on-failure -R test_io </dev/null
popd

mkdir ${BUILD_DIR}/Netopeer2
emerge_dep Netopeer2/keystored
do_test_dep_cmake Netopeer2/keystored
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DPIDFILE_PREFIX=${RUN_TMP}" emerge_dep Netopeer2/server
do_test_dep_cmake Netopeer2/server --timeout 30 -j${CI_PARALLEL_JOBS}

emerge_dep doctest
do_test_dep_cmake doctest -j${CI_PARALLEL_JOBS}

# Trompeloeil is a magic snowflake because it attempts to download and build Catch and kcov when building in a debug mode...
CMAKE_BUILD_TYPE=Release emerge_dep trompeloeil

emerge_dep docopt.cpp
do_test_dep_cmake docopt.cpp -j${CI_PARALLEL_JOBS}

# examples are broken on clang+ubsan because of their STL override
# https://github.com/AmokHuginnsson/replxx/issues/76
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_SHARED_LIBS=ON -DREPLXX_BUILD_EXAMPLES=OFF" emerge_dep replxx
do_test_dep_cmake replxx -j${CI_PARALLEL_JOBS}

# testing requires Catch, and we no longer carry that one
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_TESTING=BOOL:OFF" emerge_dep cppcodec

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_DOC=OFF -DBUILD_CODE_GEN=ON" emerge_dep sdbus-cpp
# tests perform some automatic downloads -> skip them

# verify whether sysrepo still works
sysrepoctl --list

rm -rf ${RUN_TMP}
mkdir ${RUN_TMP}
touch ${RUN_TMP}/.keep
tar -C ~/target --totals -cv . | zstd -T0 > ~/zuul-output/artifacts/${ARTIFACT}
exit 0
