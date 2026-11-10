# Oracle for the token property test: the SDK's own token rule, run by cmake.
#
# The if() below is copied unchanged from muse-gadget-sdk
# esp32/cmake/validate_config.cmake at b139b45 (the SDK_REV in env.sh). If the
# SDK changes its rule, copy it here again and the test will show whether
# build.sh still agrees.
#
# usage: cmake -DTOKENS=<file with one token per line> -P sdk_token_rule.cmake
# prints "accept" or "reject" for each line, in order.
file(STRINGS "${TOKENS}" _tokens)
foreach(CONFIG_GADGET_SDK_TOKEN IN LISTS _tokens)
    string(LENGTH "${CONFIG_GADGET_SDK_TOKEN}" GADGET_SDK_TOKEN_LENGTH)
    if(NOT GADGET_SDK_TOKEN_LENGTH EQUAL 48 OR
       NOT CONFIG_GADGET_SDK_TOKEN MATCHES "^mgst_[A-Za-z0-9_-]*[AEIMQUYcgkosw048]$")
        message(STATUS "reject")
    else()
        message(STATUS "accept")
    endif()
endforeach()
