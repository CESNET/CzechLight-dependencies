#!/bin/bash

set -eux -o pipefail
shopt -s failglob

ZUUL_JOB_NAME=$(jq < ~/zuul-env.json -r '.job')
ZUUL_PROJECT_SRC_DIR=$HOME/$(jq < ~/zuul-env.json -r '.project.src_dir')
ZUUL_PROJECT_SHORT_NAME=$(jq < ~/zuul-env.json -r '.project.short_name')

# We're reusing our artifacts, so we absolutely need a stable destdir.
PREFIX=~/target
mkdir ${PREFIX}

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

if [[ $ZUUL_JOB_NAME =~ .*-ubsan ]]; then
    export CFLAGS="-fsanitize=undefined ${CFLAGS}"
    export CXXFLAGS="-fsanitize=undefined ${CXXFLAGS}"
    export LDFLAGS="-fsanitize=undefined ${LDFLAGS}"
fi

if [[ $ZUUL_JOB_NAME =~ .*-asan ]]; then
    export CFLAGS="-fsanitize=address ${CFLAGS}"
    export CXXFLAGS="-fsanitize=address ${CXXFLAGS}"
    export LDFLAGS="-fsanitize=address ${LDFLAGS}"
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
export PKG_CONFIG_PATH=${PREFIX}/lib64/pkgconfig:${PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}


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

ARTIFACT=czechlight-dependencies-$(git --git-dir ${ZUUL_PROJECT_SRC_DIR}/.git rev-parse HEAD).tar.xz

emerge_dep libredblack --with-pic

CMAKE_OPTIONS="${CMAKE_OPTIONS} -DGEN_LANGUAGE_BINDINGS=ON -DGEN_PYTHON_BINDINGS=OFF -DGEN_JAVA_BINDINGS=OFF" emerge_dep libyang
do_test_dep_cmake libyang -j${CI_PARALLEL_JOBS}

# sysrepo needs to use a persistent repo location
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DREPOSITORY_LOC=${PREFIX}/etc-sysrepo" emerge_dep sysrepo

# These tests are only those which can run on the global repo.
# They also happen to fail when run in parallel. That's expected, they manipulate a shared repository.
do_test_dep_cmake sysrepo
# Now build it once again somewhere else and execute the whole testsuite on them.
mkdir ${BUILD_DIR}/build-sysrepo-tests
pushd ${BUILD_DIR}/build-sysrepo-tests
cmake -GNinja ${CMAKE_OPTIONS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-Debug} -DCMAKE_INSTALL_PREFIX=${PREFIX} \
${ZUUL_PROJECT_SRC_DIR}/sysrepo
ninja-build
ctest --output-on-failure
popd

emerge_dep libnetconf2
do_test_dep_cmake libnetconf2 -j${CI_PARALLEL_JOBS}

mkdir ${BUILD_DIR}/Netopeer2
emerge_dep Netopeer2/keystored
do_test_dep_cmake Netopeer2/keystored
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DPIDFILE_PREFIX=${PREFIX}/var-run" emerge_dep Netopeer2/server
do_test_dep_cmake Netopeer2/server --timeout 30 -j${CI_PARALLEL_JOBS}

emerge_dep Catch
do_test_dep_cmake Catch -j${CI_PARALLEL_JOBS}

# Trompeloeil is a magic snowflake because it attempts to download and build Catch and kcov when building in a debug mode...
CMAKE_BUILD_TYPE=Release emerge_dep trompeloeil

emerge_dep docopt.cpp
do_test_dep_cmake docopt.cpp -j${CI_PARALLEL_JOBS}

emerge_dep spdlog
do_test_dep_cmake spdlog -j${CI_PARALLEL_JOBS}

# examples are broken on clang+ubsan because of their STL override
CMAKE_OPTIONS="${CMAKE_OPTIONS} -DBUILD_SHARED_LIBS=ON -DREPLXX_BuildExamples=OFF" emerge_dep replxx
do_test_dep_cmake replxx -j${CI_PARALLEL_JOBS}

mkdir ${BUILD_DIR}/boost
pushd ${BUILD_DIR}/boost
BOOST_VERSION=boost_1_69_0
wget https://ci-logs.gerrit.cesnet.cz/t/public/mirror/buildroot/boost/${BOOST_VERSION}.tar.bz2
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

tar -C ~/target -cvJf ~/zuul-output/artifacts/${ARTIFACT} .
exit 0
