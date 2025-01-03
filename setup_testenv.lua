swg = {}
swg.rs485_maxlength = 2048
swg.rs485error_busmess = -1
swg.rs485error_noreply = -2
swg.rs485error_byte = -3
swg.rs485error_overflow = -5
swg.tcperror_timeout = -1
swg.tcperror_read = -2
swg.tcperror_write = -3
swg.tcperror_connect = -4
swg.interface_rs485 = 1
swg.interface_tcp = 2

swg.now = function()
    return os.time() * 1000
end

swg.timer = function()
    error("not implements yet")
end

swg.firstwrite = swg.timer
swg.getwrite = swg.timer
swg.sndrcv485 = swg.timer
swg.sndrcvtcp = swg.timer
swg.tcpreset = swg.timer
swg.updatepoint = swg.timer
swg.pointvalue = swg.timer
swg.devicestatus = swg.timer
swg.onoff = swg.timer

return _ENV
