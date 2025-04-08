#!/bin/bash

set -eux -o pipefail
shopt -s failglob

ZUUL_JOB_NAME=$(jq < ~/zuul-env.json -r '.job')
ZUUL_PROJECT_SRC_DIR=$HOME/$(jq < ~/zuul-env.json -r '.project.src_dir')
ZUUL_PROJECT_SHORT_NAME=$(jq < ~/zuul-env.json -r '.project.short_name')
ZUUL_PROJECT_NAME=$(jq < ~/zuul-env.json -r '.project.name')
ZUUL_SRC_COMMON_PREFIX=${ZUUL_PROJECT_SRC_DIR:0:-${#ZUUL_PROJECT_NAME}}

# We're reusing our artifacts, so we absolutely need a stable destdir.
PREFIX=~/target
mkdir ${PREFIX}
RUN_TMP=${PREFIX}/run-tmp
mkdir ${RUN_TMP}

CI_PARALLEL_JOBS=$(awk -vcpu=$(getconf _NPROCESSORS_ONLN) 'BEGIN{printf "%.0f", cpu*1.3+1}')
CMAKE_OPTIONS="-DCMAKE_INSTALL_RPATH:INTERNAL=${PREFIX}/lib64 -DCMAKE_INSTALL_RPATH_USE_LINK_PATH:INTERNAL=ON"
CFLAGS="-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"
CXXFLAGS="-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"
LDFLAGS=""

EXTRA_OPTIONS_SYSREPO=""
EXTRA_OPTIONS_NETOPEER2=""

if [[ $ZUUL_JOB_NAME =~ .*-clang.* ]]; then
    export CC=clang
    export CXX=clang++
    export LD=clang
    # https://github.com/doctest/doctest/issues/766
    # https://github.com/doctest/doctest/issues/774
    export CXXFLAGS="${CXXFLAGS} -Wno-unsafe-buffer-usage"
fi

if [[ $ZUUL_JOB_NAME =~ .*-gcc$ ]]; then
    # This changes behavior of netopeer2 (and sysrepo) in a rather subtle way. Try to cover both via our build matrix.
    EXTRA_OPTIONS_SYSREPO="-DSYSREPO_SUPERUSER_UID=${UID}"
    EXTRA_OPTIONS_NETOPEER2="-DNACM_RECOVERY_UID=${UID}"
fi

if [[ $ZUUL_JOB_NAME =~ .*-asan-ubsan ]]; then
    export CFLAGS="-fsanitize=address,undefined -Wp,-U_FORTIFY_SOURCE ${CFLAGS}"
    export CXXFLAGS="-fsanitize=address,undefined -Wp,-U_FORTIFY_SOURCE ${CXXFLAGS}"
    export LDFLAGS="-fsanitize=address,undefined ${LDFLAGS}"
    export ASAN_OPTIONS=intercept_tls_get_addr=0,log_to_syslog=true,handle_abort=2,strip_path_prefix=${ZUUL_SRC_COMMON_PREFIX}
    export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1
fi

if [[ $ZUUL_JOB_NAME =~ .*-tsan ]]; then
    export CFLAGS="-fsanitize=thread -Wp,-U_FORTIFY_SOURCE ${CFLAGS}"
    export CXXFLAGS="-fsanitize=thread -Wp,-U_FORTIFY_SOURCE ${CXXFLAGS}"
    export LDFLAGS="-fsanitize=thread ${LDFLAGS}"
    export TSAN_OPTIONS="suppressions=${ZUUL_PROJECT_SRC_DIR}/ci/tsan.supp"

    # Our TSAN does not have interceptors for a variety of "less common" functions such as pthread_mutex_clocklock.
    # Disable all functions which are optional in sysrepo/libnetconf2/netopeer2.
    CMAKE_OPTIONS="${CMAKE_OPTIONS} -DHAVE_PTHREAD_MUTEX_TIMEDLOCK=OFF -DHAVE_PTHREAD_MUTEX_CLOCKLOCK=OFF -DHAVE_PTHREAD_RWLOCK_CLOCKRDLOCK=OFF -DHAVE_PTHREAD_RWLOCK_CLOCKWRLOCK=OFF -DHAVE_PTHREAD_COND_CLOCKWAIT=OFF"

    # TSAN doesn't play nicely with SIGEV_THREAD, but netopeer2 auto-disables these based on CFLAGS
    #
    # - https://github.com/CESNET/netopeer2/pull/1420
    # - https://github.com/google/sanitizers/issues/1612
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
    ctest --timeout 180 --output-on-failure "$@"
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

emerge_dep libyang
do_test_dep_cmake libyang -j${CI_PARALLEL_JOBS}

emerge_dep doctest
do_test_dep_cmake doctest -j${CI_PARALLEL_JOBS}

emerge_dep libyang-cpp
do_test_dep_cmake libyang-cpp -j${CI_PARALLEL_JOBS}

# sysrepo needs to use a persistent repo location
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DREPO_PATH=${PREFIX}/etc-sysrepo ${EXTRA_OPTIONS_SYSREPO}" emerge_dep sysrepo
do_test_dep_cmake sysrepo -j${CI_PARALLEL_JOBS}

# Trompeloeil is a magic snowflake because it attempts to download and build Catch and kcov when building in a debug mode...
CMAKE_BUILD_TYPE=Release emerge_dep trompeloeil

emerge_dep sysrepo-cpp
do_test_dep_cmake sysrepo-cpp -j${CI_PARALLEL_JOBS}

emerge_dep libnetconf2
do_test_dep_cmake libnetconf2 -j${CI_PARALLEL_JOBS}

emerge_dep libnetconf2-cpp
do_test_dep_cmake libnetconf2-cpp -j${CI_PARALLEL_JOBS}

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DPIDFILE_PREFIX=${RUN_TMP} ${EXTRA_OPTIONS_NETOPEER2}" emerge_dep netopeer2
set_save=$-
set -E
trap "echo netopeer2 tests failed, copying logs; for ONE_NETOPEER_TEST in ${BUILD_DIR}/netopeer2/repos/*; do cp \${ONE_NETOPEER_TEST}/np2.log ~/zuul-output/logs/np2-\$(basename \${ONE_NETOPEER_TEST}).log; done" ERR
do_test_dep_cmake netopeer2 -j${CI_PARALLEL_JOBS}
trap - ERR
set +E -$set_save

# examples are broken on clang+ubsan because of their STL override
# https://github.com/AmokHuginnsson/replxx/issues/76
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_SHARED_LIBS=ON -DREPLXX_BUILD_EXAMPLES=OFF" emerge_dep replxx
do_test_dep_cmake replxx -j${CI_PARALLEL_JOBS}

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_DOC=OFF -DBUILD_CODE_GEN=ON" emerge_dep sdbus-cpp
# tests perform some automatic downloads -> skip them

# verify whether sysrepo still works
sysrepoctl --list

rm -rf ${RUN_TMP}
mkdir ${RUN_TMP}
touch ${RUN_TMP}/.keep
cp "${ZUUL_PROJECT_SRC_DIR}/ci/tsan.supp" ~/target
tar -C ~/target --totals -cv . | zstd -T0 > ~/zuul-output/artifacts/${ARTIFACT}
exit 0
