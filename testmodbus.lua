local lu = require("luaunit")

local e = require("setup_testenv")

local chunk, syntaxError = loadfile(arg[1], "t", e)
if not chunk then error(syntaxError) end

local itf, init = chunk()

lu.assertEquals(type(itf), "number")
lu.assertEquals(type(init), "function")

--Test update value of Coils
local bitvalue = "\xff\xff\xff\xff"
local readreqs = { {1, 10, 28, bitvalue}    -- 28 bits from 10
}

e.setmodbusdata(readreqs, true, 1, 11, "\x00")      -- 1 bit from 11
lu.assertEquals(readreqs[1][4], "\xfd\xff\xff\xff")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 20, "\x00")      -- 1 bits from 20
lu.assertEquals(readreqs[1][4], "\xff\xfb\xff\xff")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 36, "\x00")      -- 1 bits from 36
lu.assertEquals(readreqs[1][4], "\xff\xff\xff\xfb")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 0, "\x00\x00")   -- 9 bits from 0
lu.assertEquals(readreqs[1][4], "\xff\xff\xff\xff")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 3, "\x00\x00")   -- 9 bits from 3
lu.assertEquals(readreqs[1][4], "\xfc\xff\xff\xff")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 3, "\x00\x00\x00")   -- 17 bits from 3
lu.assertEquals(readreqs[1][4], "\x00\xfc\xff\xff")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 3, "\x00\x00\x00\x00\x00")   -- 33 bits from 3
lu.assertEquals(readreqs[1][4], "\x00\x00\x00\xfc")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 3, "\x00\x00\x00\x00\x00\x00")   -- 41 bits from 3
lu.assertEquals(readreqs[1][4], "\x00\x00\x00\x00")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 20, "\x00\x00")      -- 9 bits from 20
lu.assertEquals(readreqs[1][4], "\xff\x03\xf8\xff")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 22, "\x00\x00\x00\x00")  -- 25 bits from 22
lu.assertEquals(readreqs[1][4], "\xff\x0f\x00\x00")

readreqs[1][4] = bitvalue
e.setmodbusdata(readreqs, true, 1, 35, "\x00\x00")      -- 9 bits from 35
lu.assertEquals(readreqs[1][4], "\xff\xff\xff\x01")

local regvalue = "\xff\xff\xff\xff\xff\xff"
readreqs[2] = {3, 10, 3, regvalue}              -- 3 regs from 10
e.setmodbusdata(readreqs, true, 0, 9, "\x00\x00")   -- 1 regs from 9
lu.assertEquals(readreqs[2][4], "\xff\xff\xff\xff\xff\xff")

readreqs[2][4] = regvalue
e.setmodbusdata(readreqs, true, 0, 10, "\x00\x00")      -- 1 reg from 10
lu.assertEquals(readreqs[2][4], "\x00\x00\xff\xff\xff\xff")

readreqs[2][4] = regvalue
e.setmodbusdata(readreqs, true, 0, 11, "\x00\x00")      -- 1 reg from 11
lu.assertEquals(readreqs[2][4], "\xff\xff\x00\x00\xff\xff")

readreqs[2][4] = regvalue
e.setmodbusdata(readreqs, true, 0, 12, "\x00\x00")      -- 1 reg from 12
lu.assertEquals(readreqs[2][4], "\xff\xff\xff\xff\x00\x00")

readreqs[2][4] = regvalue
e.setmodbusdata(readreqs, true, 0, 9, "\x00\x00\x00\x00")   --2 regs from 9
lu.assertEquals(readreqs[2][4], "\x00\x00\xff\xff\xff\xff")

readreqs[2][4] = regvalue
e.setmodbusdata(readreqs, true, 0, 10, "\x00\x00\x00\x00")  --2 regs from 10
lu.assertEquals(readreqs[2][4], "\x00\x00\x00\x00\xff\xff")

readreqs[2][4] = regvalue
e.setmodbusdata(readreqs, true, 0, 12, "\x00\x00\x00\x00")  --2 regs from 12
lu.assertEquals(readreqs[2][4], "\xff\xff\xff\xff\x00\x00")

readreqs[2][4] = regvalue
e.setmodbusdata(readreqs, true, 0, 9, "\x00\x00\x11\x11\x00\x00\x22\x22\x00\x00")   --5 regs from 9
lu.assertEquals(readreqs[2][4], "\x11\x11\x00\x00\x22\x22")

readreqs[1][4] = "\x55\x55\x55\xf5"
lu.assertEquals(e.getmodbusdata(readreqs, 1, 10, 20), "\x55\x55\x55")
lu.assertEquals(e.getmodbusdata(readreqs, 1, 11, 20), "\xaa\xaa\x2a")
lu.assertEquals(e.getmodbusdata(readreqs, 1, 18, 20), "\x55\x55\xf5")
lu.assertErrorMsgContains("match", e.getmodbusdata, readreqs, 1, 9, 2)
lu.assertErrorMsgContains("match", e.getmodbusdata, readreqs, 1, 28, 12)

readreqs[2][4] = "\x11\x22\x33\x44\x55\x66"
lu.assertEquals(e.getmodbusdata(readreqs, 3, 10, 2), "\x11\x22\x33\x44")
lu.assertEquals(e.getmodbusdata(readreqs, 3, 11, 2), "\x33\x44\x55\x66")
lu.assertErrorMsgContains("match", e.getmodbusdata, readreqs, 3, 9, 2)
lu.assertErrorMsgContains("match", e.getmodbusdata, readreqs, 3, 12, 2)
