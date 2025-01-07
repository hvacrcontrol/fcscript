--Modbus v2.00, supports Modbus RTU, ASCII, TCP, RTU over TCP
--Tag config:
--bus:
--  update_interval: milliseconds, default is 10000(10 seconds)
--  offline_interval: milliseconds, default is double of update_interval
--      interval to retry on offline devices
--  command_interval: milliseconds, default is update_interval*2. For
--      commandable object, when value readback doesn't match value outputed,
--      we need to output again. This inteval limit the output frequency.
--  before_idle: milliseconds, bus idle need for sending request, only valid
--      for RS485, default 0 for ASCII, 38.5 bits for RTU
--  debug: boolean, true to print send/recv packet
--  tcp_rtu: rtu over tcp mode, default is false
--  ascii: ASCII mode, default is false
--  init: user initiaize function
--      prototype: init(ctx)
--  global_define: all properties will be propagated to global scope
--device:
--  slave
--  readreqs = {{func_code, start_addr, quantity},
--          {func_code, start_addr, quantity}
--      }
--      func_code only support 1,2,3,4
--      start_addr is starting from 0
--      After data is read from Modbus device, it will append to
--      each elment of readreqs
--  writesinglereg: boolean, when writing one reg, func_code 6 is used
--  writesinglecoil: boolean, when writing one coil, func_code 5 is used
--  endian: 1=1234, 2=2143, 3=3412, 4=4321 (default), only used in
--      default input/output
--  timeout: milliseconds, timeout for response
--  ignore_unmatch: boolean. For a commandable object, when value readback
--      don't match value written, set reliability to unreliable other.
--  init: user initialize function
--      prototype: init(ctx, device)
--point:
--  input: function to map input. If nil, default_input will be used
--      propotype: input(device, point)
--      return value, reliability
--      If value or reliability is not nil, swg.updatepoint will be called
--  output: funcion to generate output, only make sense on BACnet writable
--          object. If nil, default_output will be used
--      propotype: output(device, point, value)
--      value is the value asked to write by BACnet
--      return array of {bits_in_last_byte, address, data}, referring to
--          multiple write request. if nil is returned, no Modbus write
--          will be performed.
--      If bits_in_last_byte == 0, output to holding register, else
--          output to coil.
--  postoutput: function to be called when Modbus write is performed(not nil
--      is returned from output function).
--      propotype: postoutput(device, point, value, output_reqs)
--      return BACnet value actually write to device, it maybe different to
--          the value asked to write by BACnet
--  init: user initialize function
--      prototype: init(ctx, device, point)
--  ignore_unmatch: boolean, point specified property
--  Below parameters are only valid when default input or output function is
--      used, they will stay in point.tag scope, not to be moved to point scope
--  func_code: 1,2 is only valid for binary object.
--  addr: starting from 0
--  datatype: only valid for func_code 3 or 4. enum of
--      "u16"(unsigned 16 bits, default), "u32", "u64", "s16"(signed 16 bits),
--      "s32", "s64", "f32"(32bits float point), "f64"(64 bits float point).
--      For multistate object, only "u16" and "u32" are valid.
--      datatype is meanless for binary object.
--  ms_values: array of integer, only valid to multisate object
--      if ms_values is absense, BACnet present value 1 mapping to Modbus 0
--      if ms_values is present, BACnet present value 1 mapping to ms_values[1]
--  bit: 0~15, default is 0. Only valid for binary on input/holding register
--      or multistate object with "u16" datatype or analog object with
--      "u16" or "s16" datatype
--  bitlen: 1~16. Only valid for multistate object with "u16" datatype or
--      analog object with "u16" or "s16" datatype. if it is nil, the default
--      value is 16 - bit
--  scale, offset: scale=1.0 default, offset=0 default. Only valid for analog
--      object. BACnet value = Modbus value * scale + offset
--  datatype will be parsed to 0="u16","u32","u64", 1="s16","s32", "s64",
--      2="f32","f64".
--  bitlen will be set as actually bits used by data, for example 64 for "s64"


local crc_tbl = {
    0x0000, 0xc0c1, 0xc181, 0x0140, 0xc301, 0x03c0, 0x0280, 0xc241,
    0xc601, 0x06c0, 0x0780, 0xc741, 0x0500, 0xc5c1, 0xc481, 0x0440,
    0x0000, 0xcc01, 0xd801, 0x1400, 0xf001, 0x3c00, 0x2800, 0xe401,
    0xa001, 0x6c00, 0x7800, 0xb401, 0x5000, 0x9c01, 0x8801, 0x4400}

local function crc16(input)
    local crc = 0xffff
    for i = 1, #input do
        local c = string.byte(input, i,i)
        crc = (crc >> 8)
            ~ crc_tbl[((crc ~ c) & 0x0f) + 1]
            ~ crc_tbl[(((crc ~ c) >> 4) & 0x0f) + 17]
    end

    return string.char(crc & 0x0ff, (crc >> 8) & 0x0ff)
end


local function append_crc16(packet)
    return packet .. crc16(packet)
end


local function verify_crc16(input)
    if #input <= 2 then return nil end
    local frame = string.sub(input, 1, -3)
    if crc16(frame) == string.sub(input, -2) then
        return frame
    else
        return nil
    end
end


local function cal_lrc(input)
    local lrc = 0
    for i = 1, #input do
        local c = string.byte(input, i, i)
        lrc = lrc + c
    end
    return (-lrc) & 0x0ff
end


local function encode_ascii(input, lrc)
    local pkt = ":"
    for i = 1, #input do
        local c = string.byte(input, i,i)
        pkt = pkt .. string.format("%02X", c)
    end
    pkt = pkt .. string.format("%02X", lrc)
    return pkt .. "\r\n"
end


local function decode_ascii(input)
    --return decode packet

    local input, count = string.gsub(input, "^:+", "")
    if count == 0 then return nil end

    local cridx = string.find(input, "\r\n")
    if cridx == nil then return nil end
    input = string.sub(input, 1, cridx - 1)

    local lrc = 0
    local half = nil
    local result = ""
    for i = 1, #input do
        local c = string.byte(input, i, i)
        if c < 0x30 or c > 0x46 then return nil end
        if c > 0x39 and c < 0x41 then return nil end
        if c >= 0x41 then
            c = c - 0x41 + 10
        else
            c = c - 0x30
        end

        if half == nil then
            half = c << 4
        else
            c = half + c
            lrc = (lrc + c) & 0x0ff
            result = result .. string.char(c)
            half = nil
        end
    end

    if half ~= nil or lrc ~= 0 or #result == 0 then return nil end
    return string.sub(result, 1, #result - 1)
end


local function append_tcpheader(packet, trans_id)
    return string.char((trans_id >> 8) & 0x0ff, trans_id & 0x0ff,
            0, 0, #packet >> 8, #packet & 0x0ff) .. packet
end


local function decode_tcpheader(packet, trans_id)
    --return payload length
    if #packet < 6 then return nil end
    if (string.byte(packet,1,1) << 8)
            + string.byte(packet,2,2) ~= trans_id then return nil end
    if string.byte(packet,3,3) ~= 0 or string.byte(packet,4,4) ~= 0 then
        return nil end
    local length = (string.byte(packet,5,5) << 8) + string.byte(packet,6,6)
    if length < 2 or length > 254 then return nil end
    return length
end


local function check_exception(packet, slave, func_code)
    if #packet ~= 3 then return nil end
    if string.byte(packet,1,1) ~= slave then return nil end
    if string.byte(packet,2,2) ~= func_code|0x80 then return nil end
    return string.byte(packet,3,3)
end


local function gen_read_req(slave, func_code, start_addr, quantity)
    return string.char(slave, func_code, start_addr >> 8, start_addr & 0x0ff, quantity >> 8, quantity & 0x0ff)
end


local function check_read_rsp(packet, slave, func_code, quantity)
    --return unit data
    if func_code < 3 then
        if #packet ~= 3 + (quantity + 7) // 8 then
            return nil
        end
    else
        if #packet ~= 3 + quantity * 2 then
            return nil
        end
    end
    if string.byte(packet,1,1) ~= slave then return nil end
    if string.byte(packet,2,2) ~= func_code then return nil end
    if string.byte(packet,3,3) ~= #packet-3 then return nil end
    return string.sub(packet, 4)
end


local function gen_write_single_req(slave, func_code, data_addr, data)
    return string.char(slave, func_code, data_addr >> 8, data_addr & 0x0ff) .. data
end


local function check_write_single_rsp(packet, slave, func_code, data_addr)
    --return error msg
    if #packet ~= 6 then return "packet length" end
    if string.byte(packet,1,1) ~= slave then return "slave address" end
    if string.byte(packet,2,2) ~= func_code  then return "function code" end
    if string.byte(packet,3,3) ~= (data_addr >> 8)
            or string.byte(packet,4,4) ~= (data_addr & 0x0ff) then
        return "data address"
    end

    return nil
end


local function gen_write_multi_req(slave, func_code, start_addr, quantity, data)
    return string.char(slave, func_code, start_addr >> 8, start_addr & 0x0ff,
            quantity >> 8, quantity & 0x0ff, #data) .. data
end


local function check_write_multi_rsp(packet, slave, func_code, start_addr, quantity)
    --return error msg
    if #packet ~= 6 then return "packet length" end
    if string.byte(packet,1,1) ~= slave then return "slave address" end
    if string.byte(packet,2,2) ~= func_code  then return "function code" end
    if string.byte(packet,3,3) ~= (start_addr >> 8)
            or string.byte(packet,4,4) ~= (start_addr & 0x0ff) then
        return "data address"
    end
    if string.byte(packet,5,5) ~= (quantity >> 8)
            or string.byte(packet,6,6) ~= (quantity & 0x0ff) then
        return "quantity"
    end

    return nil
end


local function printpacket(packet, result)
    local output = {}
    local head
    if result == nil then
        head = "Tx:"
    elseif result < 0 then
        head = "Rx(" .. result .. "):"
    else
        head = "Rx:"
    end
    table.insert(output, head)
    local char_cnt = #head

    for i=1, #packet do
        if char_cnt > 120 then
            print(table.concat(output, " "))
            output = {}
            char_cnt = 2
        else
            char_cnt = char_cnt + 3
        end
        table.insert(output, string.format("%02x", string.byte(packet,i,i)))
    end
    print(table.concat(output, " "))
end


local once_callback, tcp_callback

local function send_request(ctx, packet, timeout)
    if ctx.type == swg.interface_rs485 then
        if ctx.ascii then
            packet = encode_ascii(packet, cal_lrc(packet))
            swg.sndrcv485(packet, ctx.before_idle, timeout, 516, once_callback)
        else
            packet = append_crc16(packet)
            swg.sndrcv485(packet, ctx.before_idle, timeout, 256, once_callback)
        end
    elseif ctx.tcp_rtu then
        packet = append_crc16(packet)
        -- send request and receive all response
        -- we assume the response will come in one tcp packet
        swg.sndrcvtcp(packet, 2, 257, timeout, once_callback)
    else
        if not ctx.trans_id then
            ctx.trans_id = 0
        else
            ctx.trans_id = ctx.trans_id + 1
            if ctx.trans_id > 65535 then ctx.trans_id = 0 end
        end
        packet = append_tcpheader(packet, ctx.trans_id)
        -- send request and receive response header
        swg.sndrcvtcp(packet, 6, 6, timeout, tcp_callback)
        ctx.tcp_ts = swg.now()
        ctx.tcp_header = nil
    end

    if ctx.debug then
        printpacket(packet, nil)
    end
end


local function send_read_request(ctx)
    local device = ctx.devices[ctx.curr_devidx]
    local readreq = device.readreqs[ctx.curr_reqidx]
    ctx.curr_comm = {is_read=true, device=device}
    local packet = gen_read_req(device.slave,
        readreq[1], readreq[2], readreq[3])
    send_request(ctx, packet, device.timeout)
end


local function send_write_request(ctx, device, point, output_reqs)
    local req = output_reqs[1]
    local bits_in_last_byte = req[1]
    local addr = req[2]
    local data = req[3]
    local quantity, func_code
    if #data < 1 then error("no data to write") end

    if bits_in_last_byte < 0 or bits_in_last_byte > 8 then
        error("invalid bits_in_last_byte")
    end

    if bits_in_last_byte > 0 then
        if #data > 247 then
            error("too much data to write")
        end
        quantity = (#data - 1) * 8 + bits_in_last_byte
        if quantity == 1 and device.writesinglecoil then
            func_code = 5
            if (string.byte(data,1,1) & 1) ~= 0 then
                data = string.char(0xff, 0)
            else
                data = string.char(0, 0)
            end
        else
            func_code = 15
        end
    else
        if #data % 2 ~= 0 then
            error("data length not round to 2")
        end
        if #data > 246 then
            error("too much data to write")
        end
        quantity = #data / 2
        if quantity == 1 and device.writesinglereg then
            func_code = 6
        else
            func_code = 16
        end
    end

    local packet
    if func_code < 15 then
        packet = gen_write_single_req(device.slave, func_code, addr, data)
    else
        packet = gen_write_multi_req(device.slave, func_code, addr, quantity, data)
    end

    table.remove(output_reqs, 1)
    ctx.curr_comm = {is_read=false, device=device, point=point, func_code=func_code,
            addr=addr, quantity=quantity, packet=packet, output_reqs=output_reqs}
    send_request(ctx, packet, device.timeout)
end

local timer_callback
local max_err_cnt = 3

local function read_next(ctx)
    local now = swg.now()
    ctx.curr_reqidx = 1
    ctx.err_cnt = 0
::continue::
    ctx.curr_devidx = ctx.curr_devidx + 1
    if ctx.curr_devidx > #ctx.devices then
        swg.timer(0, ctx.update_interval - (now - ctx.poll_ts), timer_callback)
        return
    end

    local device = ctx.devices[ctx.curr_devidx]
    if device.fail_ts and now - device.fail_ts <= ctx.offline_interval then
        goto continue
    end

    send_read_request(ctx)
end


local function poll_restart(ctx)
    ctx.poll_ts = swg.now()
    ctx.curr_devidx = 0
    read_next(ctx)
end


function timer_callback(ctx)
::continue::
    local devidx, pntidx, value = swg.firstwrite()
    if devidx == nil then
        local now = swg.now()
        if now - ctx.poll_ts < ctx.update_interval then
            swg.timer(0, ctx.update_interval - (now - ctx.poll_ts), timer_callback)
        else
            poll_restart(ctx)
        end
        return
    end

    local device = ctx.devices[devidx]
    local point = device.points[pntidx]
    if value == nil then    --relinguish
        point.last_output = nil
        goto continue
    end

    if device.fail_ts then goto continue end

    local last_value
    if point.last_output ~= nil then
        last_value = point.last_output
    else
        local value, reliability = swg.pointvalue(devidx, pntidx)
        if reliability == 0 then
            last_value = value
        end
    end

    if value == last_value then
        point.last_output = value
        goto continue
    end

    local output = point.output == nil and default_output or point.output

    local output_reqs = output(device, point, value)
    if output_reqs == nil or #output_reqs == 0 then     --no need to write
        goto continue
    end

    local postoutput = point.postoutput == nil
        and default_postoutput or point.postoutput

    local output_value = postoutput(device, point, value, output_reqs)
    point.last_output = output_value
    if output_value == last_value then goto continue end

    ctx.err_cnt = 0
    send_write_request(ctx, device, point, output_reqs)
end


local function scan_commandable(ctx, devidx, start)
    --For commandable object, when value readback doesnot match value outputed,
    --we need to output again.
    local device = ctx.devices[devidx]
    local now = swg.now()

    while true do
        if start then
            if device.curr_scanidx == nil then device.curr_scanidx = #device.points end
            device.scan_start = device.curr_scanidx
            start = false
        elseif device.curr_scanidx == device.scan_start then break end

        device.curr_scanidx = device.curr_scanidx + 1
        if device.curr_scanidx > #device.points then
            device.curr_scanidx = 1
        end

        local point = device.points[device.curr_scanidx]
        if not point.commandable then goto continue end
        if now - point.output_ts <= ctx.command_interval then goto continue end

        local value = swg.getwrite(devidx, device.curr_scanidx)
        if value == nil then    --relinguish
            point.last_output = nil
            goto continue
        end

        local last_value, last_reliability = swg.pointvalue(devidx,
                device.curr_scanidx)
        if last_reliability ~= 0 then last_value = nil end

        if value == last_value then
            point.last_output = value
            goto continue
        end

        local output = point.output == nil and default_output or point.output

        local output_reqs = output(device, point, value)
        if output_reqs == nil or #output_reqs == 0 then goto continue end

        local postoutput = point.postoutput == nil
            and default_postoutput or point.postoutput

        local output_value = postoutput(device, point, value, output_reqs)
        point.last_output = output_value
        if output_value == last_value then goto continue end

        ctx.err_cnt = 0
        send_write_request(ctx, device, point, output_reqs)
        do return true end

        ::continue::
    end

    return false --end of scan
end


local function write_callback(ctx, result, data)
    if result >= 0 then
        if check_exception(data, ctx.curr_comm.device.slave, ctx.curr_comm.func_code) ~= nil then
            result = 0  --regards it as success
        else
            local err
            if ctx.curr_comm.func_code < 15 then
                err = check_write_single_rsp(data, ctx.curr_comm.device.slave,
                    ctx.curr_comm.func_code, ctx.curr_comm.addr)
            else
                err = check_write_multi_rsp(data, ctx.curr_comm.device.slave,
                    ctx.curr_comm.func_code, ctx.curr_comm.addr, ctx.curr_comm.quantity)
            end
            if err then
                result = -100
                ctx.err_cnt = max_err_cnt
            end
        end
    end

    if result < 0 then
        if ctx.type ~= swg.interface_rs485 then swg.tcpreset() end

        print("Write failed(" .. result .. ") slave "
                .. ctx.curr_comm.device.slave .. " func code "
                .. ctx.curr_comm.func_code .. " addr "
                .. ctx_curr_comm.addr)
        ctx.err_cnt = ctx.err_cnt + 1
        if ctx.err_cnt < max_err_cnt then
            send_request(ctx, ctx.curr_comm.packet, ctx.curr_comm.device.timeout)
            return
        end
    elseif #ctx.curr_comm.output_reqs ~= 0 then     --next write req
        send_write_request(ctx, ctx.curr_comm.device, ctx.curr_comm.point, ctx.curr_comm.output_reqs)
        return
    end

    ctx.curr_comm.point.output_ts = swg.now()
    ctx.curr_comm = nil

    if ctx.curr_devidx > #ctx.devices then --write at end of polling
        local now = swg.now()
        if now - ctx.poll_ts > ctx.update_interval then
            poll_restart(ctx)
        else
            swg.timer(0, ctx.update_interval - (now - ctx.poll_ts), timer_callback)
        end
    elseif result < 0 or not scan_commandable(ctx, ctx.curr_devidx, false) then
        --give up when scan commandable point or scan finished
        read_next(ctx)
    end
end


local function read_callback(ctx, result, data)
    local device = ctx.devices[ctx.curr_devidx]
    local readreq = device.readreqs[ctx.curr_reqidx]

    if result >= 0 then
        if check_exception(data, device.slave, readreq[1]) ~= nil then
            result = -1000
        else
            data = check_read_rsp(data, device.slave, readreq[1], readreq[3])
            if data == nil then
                result = -100
            end
        end

        if result < 0 then
            ctx.err_cnt = max_err_cnt
        end
    end

    if result < 0 then
        if ctx.type ~= swg.interface_rs485 then swg.tcpreset() end

        print("Read failed(" .. result .. ") on device " .. ctx.curr_devidx
                .. " request " .. ctx.curr_reqidx)
        ctx.err_cnt = ctx.err_cnt + 1
        if device.fail_ts or ctx.err_cnt >= max_err_cnt then
            device.fail_ts = swg.now()  --flags for offline
            swg.onoff(ctx.curr_devidx, false)
            read_next(ctx)
        else
            send_read_request(ctx)
        end
        return
    else
        readreq[4] = data
        ctx.curr_reqidx = ctx.curr_reqidx + 1
        if ctx.curr_reqidx <= #device.readreqs then
            ctx.err_cnt = 0
            send_read_request(ctx)
            return
        end
    end

    swg.onoff(ctx.curr_devidx, true)
    device.fail_ts = nil

    for pidx, point in ipairs(device.points) do
        local input = point.input == nil and default_input or point.input

        if not point.commandable then point.last_output = nil end

        local value, reliability = input(device, point)
        if point.last_output ~= nil and value ~= point.last_output
                and reliability == 0 then
            local ignore_unmatch
            if point.ignore_unmatch ~= nil then
                ignore_unmatch = point.ignore_unmatch
            else
                ignore_unmatch = device.ignore_unmatch
            end

            if not ignore_unmatch then reliability = 7 end
        end

        swg.updatepoint(ctx.curr_devidx, pidx, value, reliability)
    end

    if scan_commandable(ctx, ctx.curr_devidx, true) then
        return
    end

    read_next(ctx)
end


function once_callback(ctx, result, data)
    if ctx.debug then
        printpacket(data, result)
    end

    if result >= 0 then
        if ctx.type == swg.interface_rs485 and ctx.ascii then
            data = decode_ascii(data)
        else
            data = verify_crc16(data)
        end
        if data == nil then
            result = -100
        end
    end

    if ctx.curr_comm.is_read then
        read_callback(ctx, result, data)
    else
        write_callback(ctx, result, data)
    end
end


function tcp_callback(ctx, result, data)
    if ctx.tcp_header == nil and result >= 0 then
        local length = decode_tcpheader(data, ctx.trans_id)
        if length == nil then
            result = -100
        else
            ctx.tcp_header = data
            local now = swg.now()
            -- to receive response body
            swg.sndrcvtcp(nil, length, length,
                ctx.curr_comm.device.timeout - (now - ctx.tcp_ts),
                tcp_callback)
            return
        end
    end

    if ctx.debug then
        if ctx.tcp_header == nil then
            printpacket(data, result)
        else
            printpacket(ctx.tcp_header .. data, result)
        end
    end

    if ctx.curr_comm.is_read then
        read_callback(ctx, result, data)
    else
        write_callback(ctx, result, data)
    end
end


function setmodbusdata(readreqs, writable, bits_in_last_byte, addr, data)
    --the value read from device is stored in readreqs
    --when we write to device, we can update stored value
    local quantity
    if bits_in_last_byte == 0 then --holding register
        quantity = #data / 2
    else
        quantity = (#data - 1) * 8 + bits_in_last_byte
    end

    for _, req in ipairs(readreqs) do
        if addr >= req[2] + req[3] then goto continue end
        if req[2] >= addr + quantity then goto continue end

        local t = {}
        if bits_in_last_byte == 0 then --holding register
            if req[1] ~= (writable and 3 or 4) then goto continue end

            if addr > req[2] then
                table.insert(t, string.sub(req[4], 1, (addr - req[2]) * 2))
                table.insert(t, string.sub(data, 1, (req[2] + req[3] - addr) * 2))
            else
                table.insert(t, string.sub(data, (req[2] - addr) * 2 + 1,
                        (req[2] + req[3] - addr) * 2))
            end

            local left = req[2] + req[3] - addr - quantity
            if left > 0 then
                table.insert(t, string.sub(req[4], left * -2))
            end
        else    --coil
            if req[1] ~= (writable and 1 or 2) then goto continue end

            local bits = (addr - req[2]) % 8

            local startidx = (addr - req[2]) // 8 + 1
            if startidx > 1 then
                table.insert(t, string.sub(req[4], 1, startidx - 1))
            end

            local endidx = (addr + quantity - req[2]) // 8
            local srcidx = (req[2] - addr) // 8 + 1
            local half

            if startidx < 1 then
                startidx = 1
                half = string.byte(data, srcidx, srcidx)
                half = half >> (8 - bits)   -- save highest bits
                srcidx = srcidx + 1
            end

            if srcidx < 1 then
                srcidx = 1
                half = string.byte(req[4], startidx, startidx)
                half = half & ~(-1 << bits)     --save lowest bits
            end

            if endidx > #req[4] then endidx = #req[4] end

            for _ = startidx, endidx do
                local byte = string.byte(data, srcidx, srcidx)
                table.insert(t, string.char(half + ((byte << bits) & 0x0ff)))
                half = byte >> (8 - bits)
                srcidx = srcidx + 1
            end

            if endidx < #req[4] then
                local left_bits = (addr + quantity - req[2]) % 8
                local byte
                if left_bits > bits then
                    byte = string.byte(data, srcidx, srcidx)
                    half = half + (byte << bits)
                end
                half = half & ~(-1 << left_bits)
                byte = string.byte(req[4], endidx+1, endidx+1)
                byte = byte & (-1 << left_bits)  -- use highest bits
                table.insert(t, string.char(half + byte))
            end

            table.insert(t, string.sub(req[4], endidx+2))
        end

        req[4] = table.concat(t)
        ::continue::
    end
end


function getmodbusdata(readreqs, func_code, addr, quantity)
    for reqidx = #readreqs, 1, -1 do
        local req = readreqs[reqidx]
        if req[1] ~= func_code then goto continue end
        if req[2] > addr then goto continue end
        if addr + quantity > req[2] + req[3] then goto continue end

        if req[4] == nil then return nil end

        if func_code >= 3 then   --register
            return req[4]:sub((addr - req[2]) * 2 + 1, (addr + quantity - req[2]) * 2)
        else    --coil or discrete
            local bits = (addr - req[2]) % 8
            local t = {}

            local startidx = (addr - req[2]) // 8 + 1
            local endidx = (addr + quantity - req[2] + 7) // 8
            local half = req[4]:byte(startidx, startidx)
            half = half >> bits     -- save highest bits

            for idx = startidx + 1, endidx do
                local byte = req[4]:byte(idx, idx)
                table.insert(t, string.char(half + ((byte << (8 - bits)) & 0x0ff)))
                half = byte >> bits
            end

            if quantity > #t * 8 then
                table.insert(t, string.char(half))
            end

            return table.concat(t)
        end

        ::continue::
    end

    error("no readreqs match")
end


function reorder_registers(value)
    local ordered = ""
    for i = 1, #value, 2 do
        ordered = value:sub(i, i+1) .. ordered
    end
    return ordered
end


function default_input(device, point)
    --return BACnet value, reliability
    local value
    if point.obj_type == "b" then
        value = getmodbusdata(device.readreqs, point.tag.func_code,
                point.tag.addr, 1)

        if point.tag.func_code >= 3 then
            value = string.unpack(((device.endian & 1 ~= 0) and "<I2" or ">I2"),
                    value)
            value = (value & (1 << point.tag.bit)) ~= 0
        else
            value = (value:byte(1,1) & 1) ~= 0
        end
    else
        value = getmodbusdata(device.readreqs, point.tag.func_code,
                point.tag.addr, (point.tag.bitlen + 15) // 16)
        if #value > 2 and (device.endian & 2) ~= 0 then
            --register order not consistent with byte order, reorder it
            value = reorder_registers(value)
        end

        if point.tag.datatype == 2 then --float
            local format = ((device.endian & 1 ~= 0) and "<" or ">") ..
                    ((point.tag.bitlen==32) and "f" or "d")
            value = string.unpack(format, value)
            if value ~= value then  --NaN
                return nil, 7   --unreliable other
            end
        else
            local format = ((device.endian & 1 ~= 0) and "<I" or ">I") ..
                   ((point.tag.bitlen + 15) // 16) * 2
            value = string.unpack(format, value)

            if point.tag.datatype == 0 then --unsigned
                if value < 0 then   --overflow
                    value = ((-1 >> 2) + 1) * 4.0 + value
                end
                if point.tag.bitlen < 16 then
                    --multistate/analog on partial register
                    value = (value >> point.tag.bit)
                            & ~(-1 << point.tag.bitlen)
                end
            else    --signed
                if point.tag.bit then value = value >> point.tag.bit end
                if value & (1 << (point.tag.bitlen - 1)) ~= 0 then --negative
                    value = -1 - ((~value) & ~(-1 << point.tag.bitlen))
                end
            end
        end

        if point.obj_type == 'a' then   --analog
            value = value * 1.0
            if point.tag.scale ~= nil then
                value = value * point.tag.scale
            end
            if point.tag.offset ~= nil then
                value = value + point.tag.offset
            end
        elseif point.tag.ms_values == nil then --multistate default mapping
            value = value + 1
            if value > point.max_value then --overflow
                return nil, 7   --unreliable other
            end
        else --multisate with value mapping
            for i = 1, point.max_value do
                if value == point.tag.ms_values[i] then
                    return i, 0
                end
            end
            return nil, 7
        end
    end

    return value, 0
end


function default_postoutput(device, point, value, output_reqs)
    --return BACnet Value actually output
    for _, req in ipairs(output_reqs) do
        setmodbusdata(device.readreqs,
                point.tag.func_code&1 == 1,  --coil or holding from func_code
                table.unpack(req))
    end
    local input = point.input == nil and default_input or point.input
    return input(device, point)
end


function default_output(device, point, value)
    --return {{bits_in_last_byte, addr, data}}
    local bits_in_last_byte, output, last, format
    if point.tag.func_code >= 3 and point.tag.bitlen < 16 then
        last = getmodbusdata(device.readreqs, point.tag.func_code,
                point.tag.addr, 1)
        format = (device.endian & 1 ~= 0) and "<I2" or ">I2"
        last = string.unpack(format, last)
    end

    if point.obj_type == 'a' then
        if point.tag.offset ~= nil then value = value - point.tag.offset end
        if point.tag.scale ~= nil then value = value / point.tag.scale end
    end

    if point.obj_type == "b" then
        if point.tag.func_code >= 3 then
            last = last & ~(1 << point.tag.bit)
            if value then last = last + (1 << point.tag.bit) end
            output = string.pack(format, last)
            bits_in_last_byte = 0
        else
            output = string.char((value and 1 or 0))
            bits_in_last_byte = 1
        end
    elseif point.tag.datatype == 2 then     --float
        format = ((device.endian & 1 ~= 0) and "<" or ">") ..
                ((point.tag.bitlen==32) and "f" or "d")
        output = string.pack(format, value)
        bits_in_last_byte = 0
    else
        if point.obj_type == 'm' then   --multistate
            value = point.tag.ms_values and point.tag.ms_values[value]
                or (value - 1) 
        else    --analog
            if point.tag.datatype == 0 then     --unsigned
                local max = ~(-1 << point.tag.bitlen)
                if value <= 0 then value = 0
                elseif max < 0 then     --lua integer overflow
                    if -value <= ~(max >> 1) then
                        value = max
                    else
                        value = math.floor(-value + 0.5)
                        value = ~value + 1
                    end
                elseif value >= max then value = max
                else value = math.floor(value + 0.5) end
            else    --signed
                local max =  (1 << (point.tag.bitlen - 1)) - 1
                local min = -1 - max
                if value >= max then value = max
                elseif value <= min then value = min
                else value = math.floor(value + 0.5) end
            end
        end

        if point.tag.bitlen < 16 then
            last = last & ~((~(-1 << point.tag.bitlen)) << point.tag.bit)
            value = last + (value << point.tag.bit)
        end

        format = ((device.endian & 1 ~= 0) and "<" or ">") ..
                ((point.tag.datatype == 0) and "I" or "i") ..
                ((point.tag.bitlen + 15) // 16) * 2
        output = string.pack(format, value)
        bits_in_last_byte = 0
    end

    if #output > 2 and (device.endian & 2) ~= 0 then
        --register order not consistent with byte order, reorder it
        output = reorder_registers(output)
    end

    if point.obj_type == 'a' and point.tag.datatype ~= 3 then
        --ananlog present_value is float, so 2 different BACnet values may map
        --to same Modbus result, when the datatype is not float, check it
        last = getmodbusdata(device.readreqs, point.tag.func_code,
                point.tag.addr, (point.tag.bitlen + 15) // 16)
        if output == last then return nil end
    end

    return {{bits_in_last_byte, point.tag.addr, output}}
end


local function check_readreqs(readreqs)
    if readreqs == nil then
        error("readreqs not defined")
    end
    if #readreqs == 0 then
        error("empty readreqs")
    end

    for _, req in ipairs(readreqs) do
        if req[1] == nil or req[1] ~= math.floor(req[1])
                or req[1] < 1 or req[1] > 4 then
            error("invalid func_code")
        end

        if req[2] == nil or req[2] ~= math.floor(req[2])
                or req[2] < 0 or req[2] > 65535 then
            error("invalid star_addr")
        end

        if req[3] == nil or req[3] ~= math.floor(req[3])
                or req[3] < 1 then
            error("invalid quantity")
        end
        if req[2] + req[3] > 65536 then
            error("address space overflow")
        end
        if (req[1] < 3 and req[3] > 2000)
                or (req[1] >= 3 and req[3] > 125) then
            error("too large quantity")
        end

        req[4] = nil
    end
end


local function check_multistate(point, tag)
    local values = tag.ms_values
    if type(values) ~= "table" then
        error("ms_values shall be a table")
    end

    if #values < point.max_value then
        error("length of ms_values shall be greater or equal to number_of_states")
    end

    local reverse = {}
    local max = (1 << tag.bitlen) - 1
    for i = 1, point.max_value do
        if type(values[i]) ~= "number" then
            error("There is no number in ms_values")
        end
        local v = math.floor(values[i])
        if v < -(max + 1) or v > max then
            error("value in ms_values over range")
        end
        v = v & max
        if reverse[v] ~= nil then
            error("duplicated value in ms_values")
        end
        values[i] = v
        reverse[v] = i
    end
end


local function check_bit(tag)
    if tag.bit == nil then tag.bit = 0
    elseif tag.bit ~= math.floor(tag.bit)
            or tag.bit < 0 or tag.bit > 15 then
        error("invalid bit")
    end

    if tag.bitlen == nil then
        tag.bitlen = 16 - tag.bit
    elseif tag.bitlen ~= math.floor(tag.bitlen)
            or tag.bitlen < 1 or tag.bitlen > 16 - tag.bit then
        error("invalid bitlen")
    end
end


local function init_point(point)
    local tag = load("return {" .. point.tag .. "\n}", "point tag", "t", _ENV)
    if tag == nil then
        error("invalid tag: " .. point.tag)
    end
    tag = tag()
    if tag.input ~= nil then
        if type(tag.input) ~= "function" then
            error("input shall be function")
        end
        point.input = tag.input
        tag.input = nil
    end
    if point.commandable then
        point.ignore_unmatch = tag.ignore_unmatch
        tag.ignore_unmatch = nil
    end
    if not point.read_only then
        if tag.output ~= nil then
            if type(tag.output) ~= "function" then
                error("output shall be function")
            end
            point.output = tag.output
            tag.output = nil
        end
        if tag.postoutput ~= nil then
            if type(tag.postoutput) ~= "function" then
                error("postoutput shall be function")
            end
            point.postoutput = tag.postoutput
            tag.postoutput = nil
        end
        point.output_ts = 0.0
    end

    if point.input == nil or (point.output == nil and not point.read_only) then
        if tag.func_code ~= math.floor(tag.func_code) or
                tag.func_code < 1 or tag.func_code > 4 then
            error("invalid func_code")
        end

        if tag.addr == nil
                or tag.addr ~= math.floor(tag.addr)
                or tag.addr < 0 or tag.addr > 65535 then
            error("invalid addr")
        end

        if point.obj_type ~= 'b' and tag.func_code < 3 then
            error("coil/discrete can not map to ananlog or multistate")
        end

        if not point.read_only and point.output == nil and (tag.func_code & 1) == 0 then
            error("discrete or input register cannot map to writable/commandable object")
        end

        if tag.func_code >= 3 then
            if point.obj_type == 'b' then
                if tag.bit == nil or tag.bit ~= math.floor(tag.bit)
                        or tag.bit < 0 or tag.bit > 15 then
                    error("invalid bit")
                end
                tag.datatype = nil
                tag.bitlen = 1
            elseif point.obj_type == 'm' then
                if tag.datatype == nil or tag.datatype == "u16" then
                    check_bit(tag)
                elseif tag.datatype == "u32" then
                    tag.bitlen = 32
                else
                    error("invalid datatype")
                end
                tag.datatype = 0
                if tag.ms_values ~= nil then
                    check_multistate(point, tag)
                end
            else    --analog
                if tag.scale ~= nil and type(tag.scale) ~= "number" then
                    error("scale shall be number")
                elseif tag.scale == 0 or tag.scale ~= tag.scale
                        or tag.scale == math.huge
                        or tag.scale == -math.huge then
                    error("invalid scale")
                end

                if tag.offset ~= nil and type(tag.offset) ~= "number" then
                    error("offset shall be number")
                elseif tag.offset ~= tag.offset or tag.offset == math.huge
                        or tag.offset == -math.huge then
                    error("invalid offset")
                end

                if tag.datatype == nil then
                    tag.datatype = "u16"
                elseif tag.datatype == "s16" or tag.datatype == "u16" then
                elseif tag.datatype == "s32" or tag.datatype == "u32"
                        or tag.datatype == "f32" then
                    tag.bitlen = 32
                elseif tag.datatype == "s64" or tag.datatype == "u64"
                        or tag.datatype == "f64" then
                    tag.bitlen = 64
                else
                    error("invalid datatype")
                end

                if string.sub(tag.datatype, 2) == "16" then
                    check_bit(tag)
                end

                if string.sub(tag.datatype,1,1) == "u" then
                    tag.datatype = 0
                elseif string.sub(tag.datatype,1,1) == "s" then
                    tag.datatype = 1
                else
                    tag.datatype = 2
                end
            end

            if tag.bitlen % 16 == 0 then tag.bit = nil end

            if tag.addr + tag.bitlen / 16 > 65536 then
                error("address space overflow")
            end
        end
    end

    point.tag = tag
end


local function init(ctx)
    local tag = load("return {" .. ctx.tag .. "\n}", "bus tag", "t", _ENV)
    if tag == nil then
        error("invalid bus tag: " .. ctx.tag)
    end
    tag = tag()

    if tag.update_interval ~= nil then
        ctx.update_interval = tag.update_interval
        tag.update_interval = nil
    else
        ctx.update_interval = 10000
    end

    if tag.offline_interval ~= nil then
        ctx.offline_interval = tag.offline_interval
        tag.offline_interval = nil
        if ctx.offline_interval < ctx.update_interval then
            ctx.offline_interval = ctx.update_interval
        end
    else
        ctx.offline_interval = ctx.update_interval * 2
    end

    if tag.command_interval ~= nil then
        ctx.command_interval = tag.command_interval
        tag.command_interval = nil
    else
        ctx.command_interval = ctx.update_interval * 2
    end

    ctx.tcp_rtu = tag.tcp_rtu
    tag.tcp_rtu = nil
    ctx.ascii = tag.ascii
    tag.ascii = nil
    ctx.debug = tag.debug
    tag.debug = nil

    if ctx.type == swg.interface_rs485 then
        if tag.before_idle ~= nil then
            ctx.before_idle = tag.before_idle
            tag.before_idle = nil
        elseif ctx.ascii then
            ctx.before_idle = 0
        else
            ctx.before_idle = 1000 / ctx.baudrate * 11 * 3.5
        end
    end

    if tag.global_define ~= nil then
        for name, value in pairs(tag.global_define) do
            _ENV[name] = value
        end
        tag.global_define = nil
    end

    ctx.tag = tag

    for _, device in ipairs(ctx.devices) do
        tag = load("return {" .. device.tag .. "\n}", "device tag", "t", _ENV)
        if tag == nil then
            error("invalid device tag: " .. device.tag)
        end
        tag = tag()

        if tag.slave == nil or tag.slave ~= math.floor(tag.slave)
                or tag.slave < 0 or tag.slave > 255 then
            error("invalid slave")
        end
        device.slave = tag.slave
        tag.slave = nil

        check_readreqs(tag.readreqs)
        device.readreqs = tag.readreqs
        tag.readreqs = nil

        if tag.timeout ~= nil then
            device.timeout = math.floor(tag.timeout)
            tag.timeout = nil
        else
            device.timeout = 1000
        end

        device.writesinglecoil = tag.writesinglecoil
        tag.writesinglecoil = nil
        device.writesinglereg = tag.writesinglereg
        tag.writesinglereg = nil

        if tag.endian ~= nil then
            device.endian = math.floor(tag.endian)
            if device.endian < 1 or device.endian > 4 then
                error("invalid endian")
            end
            tag.endian = nil
        else
            device.endian = 4
        end

        device.ignore_unmatch = tag.ignore_unmatch
        tag.ignore_unmatch = nil

        device.tag = tag
        device.err_cnt = max_err_cnt;
        for _, point in ipairs(device.points) do
            init_point(point)
            if point.input == nil then  --test readreqs has its value
                getmodbusdata(device.readreqs, point.tag.func_code,
                        point.tag.addr,
                        (point.tag.func_code >= 3
                                and ((point.tag.bitlen + 15) // 16) or 1))
            end

            if type(point.tag.init) == "function" then
                local user_init = point.tag.init
                point.tag.init = nil
                user_init(ctx, device, point)
            end
        end

        if type(device.tag.init) == "function" then
            local user_init = device.tag.init
            device.tag.init = nil
            user_init(ctx, device)
        end
    end

    if type(ctx.tag.init) == "function" then
        local user_init = ctx.tag.init
        ctx.tag.init = nil
        user_init(ctx)
    end

    poll_restart(ctx)
end


return swg.interface_rs485 | swg.interface_tcp, init
