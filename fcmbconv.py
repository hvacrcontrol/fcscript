#!/usr/bin/python3
# -*- coding: utf-8 -*-

import sys
import tkinter as tk
from tkinter import filedialog, messagebox
import json
import os
import glob

MAX_JSON_FILE_LENGTH : int = 1024 * 1024
RS485_TYPE = 1
TCP_TYPE = 2

def get_basic_cfg(cfg : dict)-> dict:
    fc_cfg : dict = {"enable": False, "name": "Bus"}
    tag : str = "debug=false,\nupdate_interval=" + str(cfg["update_ms"]) \
        + ",\noffline_interval=" + str(cfg["offline_ms"])
    fc_cfg["tag"] = tag
    return fc_cfg

def set_tcp_parameter(fc_cfg : dict)-> None:
    fc_cfg["type"] = TCP_TYPE
    fc_cfg["server"] = "0.0.0.0:502"


def set_serial(cfg : dict, fc_cfg : dict)-> None:
    fc_cfg["type"] = RS485_TYPE
    fc_cfg["parity"] = cfg["parity"]

    baudrate : int = cfg["baudrate"]
    fc_cfg["baudrate"] = baudrate
    is_ascii : bool = cfg["ascii"]
    fc_cfg["bit7"] = is_ascii

    fc_cfg["frame_ms"] = 1000 / baudrate * 11 * 3.5 if not is_ascii else 1000 / baudrate * 10 * 6
    fc_cfg["resource"] = "RS485-1"

    fc_cfg["tag"] = fc_cfg["tag"] + ",\n" +  ("ascii=true," if is_ascii else "")


def get_device_cfg(cfg : dict)->dict | None:
    dev_cfg : dict = {"enable" : cfg["enable"], "name" : cfg["name"],
                      "description" : cfg["description"], "instance" : cfg["instance"]}
    tag : str = "slave=" + str(cfg["station"]) + ",\ntimeout=" + str(cfg["timeout_ms"])
    if cfg.get("single_write_coil"):
        tag = tag + ",\nwritesinglecoil=true"

    if cfg.get("single_write_reg"):
        tag = tag + ",\nwritesinglereg=true"

    byte_reverse : bool = cfg["byte_reverse"]
    integer_byte_reverse : bool = cfg["integer_byte_reverse"]
    float_byte_reverse : bool = cfg["float_byte_reverse"]
    integer_little_endian : bool = cfg["integer_little_endian"]
    float_little_endian : bool = cfg["float_little_endian"]

    if byte_reverse != integer_byte_reverse or byte_reverse != float_byte_reverse:
        messagebox.showerror(None, "Byte order for single register|big integer|float is not consistent")
        return None

    if integer_little_endian != float_little_endian:
        messagebox.showerror(None, "Byte order for bit integer|float is not consistent")
        return None

    if byte_reverse:
        if integer_little_endian:
            tag = tag + ",\nendian=1"
        else:
            tag = tag + ",\nendian=3"
    else:
        if integer_little_endian:
            tag = tag + ",\nendian=2"
        else:
            tag = tag + ",\nendian=4"

    dev_cfg["tag"] = tag
    return dev_cfg


def set_points(points : list[dict], dev_cfg : dict)->list[(int, int, int)]:
    """after set dev_cfg, return list of (func_code, 0 based start address, data length)"""
    used_address : list[(int, int, int)] = []
    fcpoints : list[dict] = []
    dev_cfg["fcpoints"] = fcpoints

    for pnt in points:
        fcpnt = {"name" : pnt["name"], "description" : pnt["description"],
                 "instance" : pnt["instance"]}
        fcpoints.append(fcpnt)

        enable : bool = pnt["enable"]
        fcpnt["enable"] = enable
        object_type : str = pnt["object_type"]
        fcpnt["object_type"] = object_type

        address : int = pnt["address"]
        func_code : int
        if pnt["address_type"] == "holding":
            func_code = 3
        elif pnt["address_type"] == "input":
            func_code = 4
        elif pnt["address_type"] == "coil":
            func_code = 1
        else:
            func_code = 2

        if object_type[1]  == "v":
            if func_code == 1 or func_code == 3:
                fcpnt["value_type"] = 0
            else:
                fcpnt["value_type"] = 1

        tag : str = "func_code=" + str(func_code) + ",\naddr=" + str(address)
        datalen : int
        if object_type[0] == "b":     #binary
            fcpnt["polarity"] = pnt["polarity"]
            if "state_texts" in pnt:
                fcpnt["state_texts"] = pnt["state_texts"]
            if func_code >= 3:  #register
                tag = tag + ",\nbit=" + str(pnt["bit_offset"])
            datalen = 1
        elif object_type[0] == "a":   #analog
            fcpnt["unit"] = pnt["unit"]
            fcpnt["cov_increment"] = pnt["cov_increment"]
            datatype : str = pnt["data_type"]
            if datatype == "float":
                datatype = "f32"
            elif datatype == "double":
                datatype = "f64"

            datalen = (int(datatype[1:]) + 15) // 16

            if datatype[0] == "o":
                messagebox.showinfo(None,\
                        ("Point" if enable else "Disabled point: ") \
                            + pnt["name"] + " need script to translate")
            else:
                tag = tag + ",\ndatatype=\"" + datatype + "\",\noffset="\
                      + str(pnt["offset"]) + ",\nscale=" + str(pnt["scale"])
                if datalen == 1:
                    if "bit_offset" in pnt:
                        tag = tag + ",\nbit=" + str(pnt["bit_offset"])
                    if "bit_len" in pnt:
                        tag = tag + ",\nbit_len=" + str(pnt["bit_len"])
        else:
            #multistate
            if "reg_num" in pnt and pnt["reg_num"] > 1:
                datalen = 2
                tag = tag + ",\ndatatype=\"u32\""
            else:
                datalen = 1
                if "bit_offset" in pnt:
                    tag = tag + ",\nbit=" + str(pnt["bit_offset"])
                if "bit_len" in pnt:
                    tag = tag + ",\nbit_len=" + str(pnt["bit_len"])

            if "state_texts" in pnt:
                fcpnt["state_texts"] = pnt["state_texts"]
                state_values : list[int] = pnt["state_values"]
                tag = tag + ",\nms_values={"
                for v in state_values:
                    tag = tag + str(v) + ", "

                tag = tag + "}"

        if object_type[1] == "o" and "output_tolerance" in pnt\
                and pnt["output_tolerance"]:
            tag = tag + ",\nignore_unmatch=true"
        fcpnt["tag"] = tag

        if enable:
            used_address.append((func_code, address, datalen))

    return used_address


def set_readreqs(cfg : dict, dev_cfg : dict, used_address : list[(int, int, int)])->None:
    readreqs : list[(int, int ,int)] = []
    used_address.sort(key = lambda pnt : pnt[0] * 100000 + pnt[1] - pnt[2]*0.0001)

    group_bit : int = cfg["group_bit"]
    unused_bit : int = cfg["unused_bit"]
    group_reg : int = cfg["group_reg"]
    unused_reg : int = cfg["unused_reg"]

    prev : tuple[int, int, int] | None = None
    for pnt in used_address:
        if prev is None:
            prev = pnt
            continue

        group : int
        unused : int
        if prev[0] <= 2:
            group = group_bit
            unused = unused_bit
        else:
            group = group_reg
            unused = unused_reg

        if pnt[0]*100000 + pnt[1] + pnt[2] - prev[0]*100000 - prev[1] > group \
                or pnt[1] - prev[1] - prev[2] > unused:
            readreqs.append(prev)
            prev = pnt
        elif pnt[1] + pnt[2] > prev[1] + prev[2]:
            prev = (prev[0], prev[1], pnt[1] + pnt[2] - prev[1])

    if prev is not None:
        readreqs.append(prev)

    tag : str = dev_cfg["tag"]
    tag = tag + ",\nreadreqs={"
    for req in readreqs:
        tag = tag + "\n{" + str(req[0]) + ", " + str(req[1]) + ", " + str(req[2]) + "},"
    tag = tag + "\n}"
    dev_cfg["tag"] = tag


def main():
    #root = tk.Tk()

    directory : str = os.path.dirname(os.path.realpath(__file__))
    files : list[str] = glob.glob(os.path.join(directory, "modbus*.lua"))

    if len(files) == 0:
        while 1:
            filepath = filedialog.askopenfilename(
                initialdir="~/",
                title="Select a script file",
                filetypes=(("FreeClient script for Modbus", "*.lua"), ("All files", "*.*")))

            if not filepath:
                return 0

            try:
                with open(filepath, 'r', encoding='utf-8-sig') as file:
                    script_text: str = file.read()
            except Exception as e:
                messagebox.showerror(None, "Error opening file: " + str(e))
                continue

            break
    else:
        while 1:
            filepath = filedialog.askopenfilename(
                initialdir=directory,
                initialfile=files[0],
                title="Select a script file",
                filetypes=(("FreeClient script for Modbus", "*.lua"), ("All files", "*.*")))

            if not filepath:
                return 0

            try:
                with open(filepath, 'r', encoding='utf-8-sig') as file:
                    script_text: str = file.read()
            except Exception as e:
                messagebox.showerror(None, "Error opening file: " + str(e))
                continue

            break

    script_name: str = os.path.basename(filepath)

    while 1:
        filepath = filedialog.askopenfilename(
            initialdir = "~/",
            title = "Select a config file",
            filetypes = (("Modbus device config file", "*.json"), ("All files", "*.*")))

        if not filepath:
            return 0

        try:
            with open(filepath, 'r', encoding='utf-8-sig') as file:
                data : str = file.read()
        except Exception as e:
            messagebox.showerror(None, "Error opening file: " + str(e))
            continue

        if len(data) > MAX_JSON_FILE_LENGTH:
            messagebox.showerror(None, "Too large config file")
            continue

        try:
            cfg : dict = json.loads(data)
        except json.JSONDecodeError:
            messagebox.showerror(None, "Not a valid json file")
            continue

        if not isinstance(cfg, dict):
            messagebox.showerror(None, "Not a json objects")
            continue

        points : list[dict] = cfg.get("points")
        if not isinstance(points, list):
            messagebox.showerror(None, "Invalid points arrays, is it a Modbus device config file?")
            continue

        fc_cfg : dict = get_basic_cfg(cfg)
        fc_cfg["script"] = {script_name : script_text}
        if not "baudrate" in cfg:
            set_tcp_parameter(fc_cfg)
        else:
            set_serial(cfg, fc_cfg)

        dev_cfg : dict = get_device_cfg(cfg)
        if not dev_cfg:
            continue

        fc_cfg["fcdevices"] = [dev_cfg]
        used_address = set_points(points, dev_cfg)
        set_readreqs(cfg, dev_cfg, used_address)
        break

    srcdir : str = os.path.dirname(filepath)

    while 1:
        filepath = filedialog.asksaveasfilename(
            initialdir = srcdir,
            title = "Save converted config to file",
            defaultextension=".json",
            filetypes = (("FreeClient bus config file", "*.json"), ("All files", "*.*")))

        if filepath:
            try:
                with open(filepath, 'w', encoding='utf-8-sig') as file:
                    file.write(json.dumps(fc_cfg))
                messagebox.showinfo(None, filepath + " is saved")
                break
            except Exception as e:
                messagebox.showerror(None, "Error saving file: " + str(e))
        else:
            if messagebox.askokcancel(None, "Really want to quit without saving?"):
                break

    return 0


if __name__ == '__main__':
    sys.exit(main())