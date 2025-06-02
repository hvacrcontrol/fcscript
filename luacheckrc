std = "lua54"

local swg={
    fields = {
        now={},
        timer={},
        firstwrite={},
        getwrite={},
        sndrcv485={},
        sndrcvtcp={},
        tcpreset={},
        updatepoint={},
        pointvalue={},
        devicestatus={},
        onoff={},
        rs485_maxlength={},
        rs485error_busmess={},
        rs485error_noreply={},
        rs485error_byte={},
        rs485error_overflow={},
        tcperror_timeout={},
        tcperror_read={},
        tcperror_write={},
        tcperror_connect={},
        interface_rs485={},
        interface_tcp={},
    }
}

local removed = {"debug", "os", "coroutine", "io", "file", "package", "collectgarbage","dofile", "dofile", "require"}

files["modbus.lua"] = {
    read_globals = {swg=swg},
    not_globals = removed,
    globals = {"default_input", "default_output", "default_postoutput", "getmodbusdata", "setmodbusdata", "reorder_registers"},
}

files["mbus.lua"] = {
    read_globals = {swg=swg},
    not_globals = removed,
}

files["setup_testenv.lua"] = {
    globals = {swg=swg},
}
