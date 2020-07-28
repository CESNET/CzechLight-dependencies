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

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DGEN_LANGUAGE_BINDINGS=ON -DGEN_PYTHON_BINDINGS=OFF -DGEN_JAVA_BINDINGS=OFF" emerge_dep libyang
do_test_dep_cmake libyang -j${CI_PARALLEL_JOBS}

# sysrepo needs to use a persistent repo location
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DREPO_PATH=${PREFIX}/etc-sysrepo -DGEN_LANGUAGE_BINDINGS=ON -DGEN_PYTHON_BINDINGS=OFF" emerge_dep sysrepo
TSAN_OPTIONS="suppressions=${ZUUL_PROJECT_SRC_DIR}/ci/tsan.supp" do_test_dep_cmake sysrepo -j${CI_PARALLEL_JOBS}

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DIGNORE_LIBSSH_VERSION=ON" emerge_dep libnetconf2
# https://github.com/CESNET/libnetconf2/issues/153
do_test_dep_cmake libnetconf2 -j${CI_PARALLEL_JOBS} -E test_io
pushd ${BUILD_DIR}/libnetconf2
ctest --output-on-failure -R test_io </dev/null
popd

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DDATA_CHANGE_WAIT=ON -DPIDFILE_PREFIX=${RUN_TMP}" emerge_dep Netopeer2
# New Netopeer2 doesn't have tests

emerge_dep doctest
do_test_dep_cmake doctest -j${CI_PARALLEL_JOBS}

# Trompeloeil is a magic snowflake because it attempts to download and build Catch and kcov when building in a debug mode...
CMAKE_BUILD_TYPE=Release emerge_dep trompeloeil

emerge_dep docopt.cpp
do_test_dep_cmake docopt.cpp -j${CI_PARALLEL_JOBS}

emerge_dep spdlog
do_test_dep_cmake spdlog -j${CI_PARALLEL_JOBS}

# examples are broken on clang+ubsan because of their STL override
# https://github.com/AmokHuginnsson/replxx/issues/76
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_SHARED_LIBS=ON -DREPLXX_BUILD_EXAMPLES=OFF" emerge_dep replxx
do_test_dep_cmake replxx -j${CI_PARALLEL_JOBS}

# testing requires Catch, and we no longer carry that one
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_TESTING=BOOL:OFF" emerge_dep cppcodec

emerge_dep pybind11
do_test_dep_cmake pybind11 -j${CI_PARALLEL_JOBS}

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_DOC=OFF -DBUILD_CODE_GEN=ON" emerge_dep sdbus-cpp
# tests perform some automatic downloads -> skip them

mkdir ${BUILD_DIR}/boost
pushd ${BUILD_DIR}/boost
BOOST_VERSION=boost_1_71_0
wget https://object-store.cloud.muni.cz/swift/v1/ci-artifacts-public/mirror/buildroot/boost/${BOOST_VERSION}.tar.bz2
tar -xf ${BOOST_VERSION}.tar.bz2
cd ${BOOST_VERSION}
./bootstrap.sh --prefix=${PREFIX} --with-toolset=${CC:-gcc}
./b2 --ignore-site-config toolset=${CC:-gcc} ${CXXFLAGS:+cxxflags="${CXXFLAGS}"} ${LDFLAGS:+linkflags="${LDFLAGS}"} cxxstd=17 \
 -j ${CI_PARALLEL_JOBS} \
  --with-system --with-thread --with-date_time --with-regex --with-serialization --with-chrono --with-atomic \
  install
popd

# verify whether sysrepo still works
sysrepoctl --list

rm -rf ${RUN_TMP}
mkdir ${RUN_TMP}
touch ${RUN_TMP}/.keep
tar -C ~/target --totals -cv . | zstd -T0 > ~/zuul-output/artifacts/${ARTIFACT}
exit 0
