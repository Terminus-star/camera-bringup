savedcmd_amd_isp4.mod := printf '%s\n'   amd_isp4.o | awk '!x[$$0]++ { print("./"$$0) }' > amd_isp4.mod
