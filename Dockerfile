# Build GNU Sather from the official GNU release, then copy the finished
# tree into a slim runtime image.
#
# The sources are the pristine sather-1.2.2 tarball from ftp.gnu.org plus
# the two small patches in patches/ that let it build and run correctly on
# a modern 64-bit host; see patches/*.patch for the reasoning. The Boehm
# collector comes from the Linux distribution: the gc4.14 tarball GNU shipped
# alongside Sather predates x86-64 entirely.
#
# We stay on 24.04: its gcc 13 accepts the implicit declarations in the
# 2005 bootstrap C as warnings, where gcc 14 and later make them hard
# errors.
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517 AS build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bzip2 \
        gcc \
        libc6-dev \
        libgc-dev \
        make \
        patch && \
    rm -rf /var/lib/apt/lists/*

# ftp.gnu.org serves the archive over HTTPS, and the pinned digest makes
# the build fail loudly if the served bytes ever change. (GNU also
# publishes a GPG signature next to the tarball for offline verification.)
ADD --checksum=sha256:75a94e3f07eccf45f8476cd074dc6ed3d1648b77006776cd44c856b7778d0545 \
    https://ftp.gnu.org/gnu/sather/sather-1.2.2.tar.bz2 /tmp/sather-1.2.2.tar.bz2

RUN tar -xjf /tmp/sather-1.2.2.tar.bz2 -C /opt && \
    mv /opt/sather-1.2.2 /opt/sather && \
    rm /tmp/sather-1.2.2.tar.bz2

WORKDIR /opt/sather
COPY patches/ /tmp/patches/

# The tarball ships 2005-vintage 32-bit x86 objects; their timestamps make
# make prefer them over freshly compiled sources, and they cannot link on
# any 64-bit host. The bootstrap C they were built from is still present.
RUN for p in /tmp/patches/*.patch; do patch -p1 < "$p"; done && \
    rm -f Boot/sacomp.code/*.o System/Common/Brahma/lib/*.a

# 'make full' bootstraps a compiler from the shipped C, then recompiles the
# compiler from the Sather sources in Compiler/, so Bin/sacomp is built
# from what is actually in this tree. 'sacomp -version' prints the version
# and then tries to compile, so with nothing to compile it exits non-zero:
# check the output, not the status.
RUN SATHER_HOME=/opt/sather make full && \
    { SATHER_HOME=/opt/sather ./Bin/sacomp -version 2>&1 || true; } | \
        grep -q 'Sather compiler version'

# The distribution's own library test suite, compiled with runtime checks
# on, exactly as the runner will compile every solution.
RUN SATHER_HOME=/opt/sather make test && \
    grep -q 'passed all' Test/test-all.output && \
    ! grep -qi 'fail' Test/test-all.output

# Prove a checked program builds and runs before shipping the tree,
# including the 32-bit INT semantics the first patch exists for.
RUN printf 'class SMOKE is\n main is\n  assert INT::asize = 32;\n  assert INT::maxint = 2147483647;\n  #OUT + "ok\\n";\n end;\nend;\n' > /tmp/smoke.sa && \
    SATHER_HOME=/opt/sather ./Bin/sacomp -chk /tmp/smoke.sa -main SMOKE -o /tmp/smoke && \
    /tmp/smoke | grep -qx ok

# Drop what only the build needed. Bin/sacomp.code is the generated C the
# compiler was linked from; Boot is the bootstrap; the rest never runs.
# Doc is kept only for its license texts, which the source headers cite.
# This is most of the tree: 12MB survives of the 60MB a full build leaves.
RUN rm -rf Boot Browser Emacs Test debian Doxyfile Manifest \
           Bin/sacomp.code Bin/sabrowse.code \
           sather_1_2_1.kdev* && \
    find Doc -type f ! -name 'GPL' ! -name 'LGPL' ! -name 'License' -delete && \
    find Doc -type d -empty -delete

FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

# sacomp emits C and shells out to make, so compiling a solution needs
# gcc, make and the GC headers at runtime; gawk and jq turn the harness's
# test records into results.json.
#
# The toolchain is then trimmed of ~110MB it can never use: sacomp always
# invokes gcc with the fixed options in System/Common/CONFIG, so the LTO
# compiler, the sanitizer runtimes, the static libc, and the alternative
# linker are all unreachable. cc1 and the shared libraries stay.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gawk \
        gcc \
        jq \
        libc6-dev \
        libgc-dev \
        make && \
    rm -rf /var/lib/apt/lists/* \
        /usr/libexec/gcc/x86_64-linux-gnu/13/lto1 \
        /usr/bin/x86_64-linux-gnu-lto-dump-13 \
        /usr/bin/x86_64-linux-gnu-ld.gold \
        /usr/bin/x86_64-linux-gnu-dwp \
        /usr/bin/x86_64-linux-gnu-gprofng* \
        /usr/bin/gprofng* \
        /usr/lib/x86_64-linux-gnu/libgprofng* \
        /usr/lib/x86_64-linux-gnu/libasan.so* \
        /usr/lib/x86_64-linux-gnu/libtsan.so* \
        /usr/lib/x86_64-linux-gnu/libhwasan.so* \
        /usr/lib/x86_64-linux-gnu/libubsan.so* \
        /usr/lib/x86_64-linux-gnu/liblsan.so* \
        /usr/lib/x86_64-linux-gnu/libc.a \
        /usr/lib/x86_64-linux-gnu/libm-2.39.a \
        /usr/lib/x86_64-linux-gnu/libmvec.a \
        /usr/lib/gcc/x86_64-linux-gnu/13/libasan* \
        /usr/lib/gcc/x86_64-linux-gnu/13/libtsan* \
        /usr/lib/gcc/x86_64-linux-gnu/13/libhwasan* \
        /usr/lib/gcc/x86_64-linux-gnu/13/libubsan* \
        /usr/lib/gcc/x86_64-linux-gnu/13/liblsan*

COPY --from=build /opt/sather /opt/sather

ENV SATHER_HOME=/opt/sather
ENV PATH="/opt/sather/Bin:${PATH}"

WORKDIR /opt/test-runner
COPY . .
RUN chmod +x bin/run.sh bin/records-to-json.awk

ENTRYPOINT ["/opt/test-runner/bin/run.sh"]
