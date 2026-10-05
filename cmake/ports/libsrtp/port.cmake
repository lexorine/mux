# mux's port of libSRTP: cmake-everywhere's, from the registry at the version
# this build pins (v0.2.32), with one patch added.
#
# The patch puts include/srtp.h where libdatachannel's
# "#include <srtp2/srtp.h>" looks for it while the library is built from its
# source tree rather than from an installed prefix -- which is how this port
# builds it. An overlay is read before the registry, so this declaration is
# the one the port comes from; the registry's fields are all restated here.
cme_declare_port(
  NAME libsrtp
  PROVIDES libSRTP srtp2
  VERSION 2.8.1
  GITHUB_REPOSITORY cisco/libsrtp
  GIT_TAG v2.8.1
  DEPENDS openssl
  OPTIONS
    "ENABLE_OPENSSL ON"
    "LIBSRTP_TEST_APPS OFF"
    "BUILD_TESTING OFF"
    "BUILD_SHARED_LIBS OFF"
    "ENABLE_WARNINGS_AS_ERRORS OFF"
  PATCHES "patches/0001-srtp2-header.patch"
  GIT_TAG_TEMPLATE "v@VERSION@"
  LICENSE BSD-3-Clause
  TARGETS libSRTP::srtp2
  CHECK_HEADER srtp2/srtp.h
)

function(cme_adapt_libsrtp source binary)
  cme_export_variable(libSRTP libSRTP_FOUND TRUE)
endfunction()
