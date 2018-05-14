
-- add modes: debug and release 
add_rules("mode.debug", "mode.release")

-- add target
target("msdsm")

    -- add rules
    add_rules("wdk.kmdf.driver")

    -- add flags for rule: wdk.tracewpp
    add_values("wdk.tracewpp.flags", "-func:TracePrint((LEVEL,FLAGS,MSG,...))")

    -- add files
    add_files("*.c", {rule = "wdk.tracewpp"}) 
    add_files("*.rc", "*.inf")
    add_files("*.mof|msdsm.mof")

    -- add file msdsm.mof and modify default wdk.mof.header for this file
    add_files("msdsm.mof", {values = {wdk_mof_header = "msdsmwmi.h"}}) 

