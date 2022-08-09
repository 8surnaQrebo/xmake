--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki, Arthapz
-- @file        msvc.lua
--

-- imports
import("core.tool.compiler")
import("core.project.project")
import("core.project.depend")
import("core.project.config")
import("utils.progress")
import("private.action.build.object", {alias = "objectbuilder"})
import("common")

-- add a module or header unit into the mapper
--
-- e.g
-- /headerUnit:angle Foo=build/.gens/Foo/rules/modules/cache/Foo.ifc
-- /headerUnit:angle glm/mat4x4.hpp=Users\arthu\AppData\Local\.xmake\packages\g\glm\0.9.9+8\91454f3ee0be416cb9c7452970a2300f\include\glm\mat4x4.hpp.ifc
--
function _add_module_to_mapper(target, argument, module, bmifile)
    local mapflags = _get_mapflags_from_mapper(target)
    local mapflag = format("%s %s=%s", argument, module, bmifile)
    local tosearch = format("%s %s=", argument, module)
    for _, line in ipairs(mapflags) do
        if line:startswith(tosearch) then
            return
        end
    end
    for _, dep in ipairs(target:orderdeps()) do
        local mapflags_ = _get_mapflags_from_mapper(dep)
        for _, line in ipairs(mapflags_) do
            if line:startswith(tosearch) then
                return
            end
        end
    end
    table.insert(mapflags, mapflag)
    common.localcache():set(_mapper_cachekey(target), mapflags)
end

function _mapper_cachekey(target)
    return target:name() .. "_mapflags"
end

-- flush mapflags to mapper file cache
function _flush_mapflags_to_mapper(target)
    -- not using set2/get2 to flush only current target mapper
    common.localcache():save(_mapper_cachekey(target))
end

-- get mapflags from mapper
function _get_mapflags_from_mapper(target)
    return common.localcache():get(_mapper_cachekey(target)) or {}
end

-- add an objectfile to the linker args
--
-- e.g
-- foo.obj
--
function _add_objectfile_to_link_arguments(target, objectfile)
    local cachekey = target:name() .. "headerunit_objectfiles"
    local cache = common.localcache():get(cachekey) or {}
    if table.contains(cache, objectfile) then
        return
    end
    table.insert(cache, objectfile)
    common.localcache():set(cachekey, cache)
    common.localcache():save(cachekey)
end

-- load module support for the current target
function load(target)
    local cachedir = common.modules_cachedir(target)
    local stlcachedir = common.stlmodules_cachedir(target)

    -- get flags
    local modulesflag = get_modulesflag(target)
    local ifcsearchdirflag = get_ifcsearchdirflag(target)

    -- add modules flags
    target:add("cxxflags", modulesflag)

    -- add stdifcdir in case of if the user ask for it
    if target:values("msvc.modules.stdifcdir") then
        local stdifcdirflag = get_stdifcdirflag(target)
        for _, toolchain_inst in ipairs(target:toolchains()) do
            if toolchain_inst:name() == "msvc" then
                local vcvars = toolchain_inst:config("vcvars")
                if vcvars.VCInstallDir and vcvars.VCToolsVersion then
                    local stdifcdir = path.join(vcvars.VCInstallDir, "Tools", "MSVC", vcvars.VCToolsVersion, "ifc", target:is_arch("x64") and "x64" or "x86")
                    if os.isdir(stdifcdir) then
                        target:add("cxxflags", {stdifcdirflag, winos.short_path(stdifcdir)}, {force = true, expand = false})
                    end
                end
                break
            end
        end
    end
end

-- provide toolchain include dir for stl headerunit when p1689 is not supported
function toolchain_includedirs(target)
    for _, toolchain_inst in ipairs(target:toolchains()) do
        if toolchain_inst:name() == "msvc" then
            local vcvars = toolchain_inst:config("vcvars")
            if vcvars.VCInstallDir and vcvars.VCToolsVersion then
                return { path.join(vcvars.VCInstallDir, "Tools", "MSVC", vcvars.VCToolsVersion, "include") }
            end
            break
        end
    end
    raise("msvc toolchain includedirs not found!")
end

-- generate dependency files
function generate_dependencies(target, sourcebatch, opt)
    local compinst = target:compiler("cxx")
    local toolchain = target:toolchain("msvc")
    local vcvars = toolchain:config("vcvars")
    local scandependenciesflag = get_scandependenciesflag(target)
    local common_args = {"-TP", scandependenciesflag}
    local cachedir = common.modules_cachedir(target)
    local changed = false
    for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
        local dependfile = target:dependfile(sourcefile)
        depend.on_changed(function ()
            if opt.progress then
                progress.show(opt.progress, "${color.build.object}generating.cxx.module.deps %s", sourcefile)
            end
            local outputdir = path.join(cachedir, path.directory(path.relative(sourcefile, projectdir)))
            if not os.isdir(outputdir) then
                os.mkdir(outputdir)
            end

            local jsonfile = path.join(outputdir, path.filename(sourcefile) .. ".json")
            if scandependenciesflag then
                local args = {jsonfile, sourcefile, "-Fo" .. target:objectfile(sourcefile)}
                os.vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, args), {envs = vcvars})
            else
                common.fallback_generate_dependencies(target, jsonfile, sourcefile)
            end
            changed = true

            local dependinfo = io.readfile(jsonfile)
            return { moduleinfo = dependinfo }
        end, {dependfile = dependfile, files = {sourcefile}})
    end
    return changed
end

-- generate target stl header units for batchjobs
function generate_stl_headerunits_for_batchjobs(target, batchjobs, headerunits, opt)
    local compinst = target:compiler("cxx")
    local toolchain = target:toolchain("msvc")
    local vcvars = toolchain:config("vcvars")
    local stlcachedir = common.stlmodules_cachedir(target)

    -- get flags
    local exportheaderflag = get_exportheaderflag(target)
    local headerunitflag = get_headerunitflag(target)
    local headernameflag = get_headernameflag(target)
    local ifcoutputflag = get_ifcoutputflag(target)
    assert(headerunitflag and headernameflag and exportheaderflag, "compiler(msvc): does not support c++ header units!")

    -- flush job
    local flushjob = batchjobs:addjob(target:name() .. "_stl_headerunits_flush_mapper", function(index, total)
        _flush_mapflags_to_mapper(target)
    end, {rootjob = opt.rootjob})

    -- build headerunits
    local common_args = {"-TP", exportheaderflag, "-c"}
    for _, headerunit in ipairs(headerunits) do
        local bmifile = path.join(stlcachedir, headerunit.name .. get_bmi_extension())
        local objectfile = bmifile .. ".obj"
        if not os.isfile(bmifile) or not os.isfile(objectfile) then
            batchjobs:addjob(headerunit.name, function(index, total)
               depend.on_changed(function()
                    if not common.localcache():get2(headerunit.name, "building") then 
                        common.localcache():set2(headerunit.name, "building", true)
                        progress.show((index * 100) / total, "${color.build.object}generating.cxx.headerunit.bmi %s", headerunit.name)
                        local args = {headernameflag .. ":angle", headerunit.name, ifcoutputflag, headerunit.name:startswith("experimental/") and path.join(stlcachedir, "experimental") or stlcachedir, "-Fo" .. objectfile}
                        os.vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, args), {envs = vcvars})
                        common.localcache():set2(headerunit.name, "building", false)
                    end

               end, {dependfile = target:dependfile(bmifile), files = {headerunit.path}})
                _add_module_to_mapper(target, headerunitflag .. ":angle", headerunit.name, path.translate(bmifile))
            end, {rootjob = flushjob})
            _add_objectfile_to_link_arguments(target, objectfile)
        end
    end
end

-- generate target stl header units for batchcmds
function generate_stl_headerunits_for_batchcmds(target, batchcmds, headerunits, opt)
    local compinst = target:compiler("cxx")
    local toolchain = target:toolchain("msvc")
    local vcvars = toolchain:config("vcvars")
    local stlcachedir = common.stlmodules_cachedir(target)

    -- get flags
    local exportheaderflag = get_exportheaderflag(target)
    local headerunitflag = get_headerunitflag(target)
    local headernameflag = get_headernameflag(target)
    local ifcoutputflag = get_ifcoutputflag(target)
    assert(headerunitflag and headernameflag and exportheaderflag, "compiler(msvc): does not support c++ header units!")

    -- build headerunits
    local common_args = {"-TP", exportheaderflag, "-c"}
    local depmtime = 0
    for _, headerunit in ipairs(headerunits) do
        local bmifile = path.join(stlcachedir, headerunit.name .. get_bmi_extension())
        local objectfile = bmifile .. ".obj"
        if not os.isfile(bmifile) or not os.isfile(objectfile) then
            local args = {headernameflag .. ":angle", headerunit.name, ifcoutputflag, headerunit.name:startswith("experimental/") and path.join(stlcachedir, "experimental") or stlcachedir, "-Fo" .. objectfile}
            batchcmds:show_progress(opt.progress, "${color.build.object}generating.cxx.headerunit.bmi %s", headerunit.name)
            batchcmds:vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, args), {envs = vcvars})
            batchcmds:add_depfiles(headerunit.path)

            _add_objectfile_to_link_arguments(target, objectfile)
        end
        _add_module_to_mapper(target, headerunitflag .. ":angle", headerunit.name, path.translate(bmifile))
        depmtime = math.max(depmtime, os.mtime(bmifile))
    end
    batchcmds:set_depmtime(depmtime)
    _flush_mapflags_to_mapper(target)
end

-- generate target user header units for batchcmds
function generate_user_headerunits_for_batchjobs(target, batchjobs, headerunits, opt)
    local compinst = target:compiler("cxx")
    local toolchain = target:toolchain("msvc")
    local vcvars = toolchain:config("vcvars")
    local cachedir = common.modules_cachedir(target)

    -- get flags
    local exportheaderflag = get_exportheaderflag(target)
    local headerunitflag = get_headerunitflag(target)
    local headernameflag = get_headernameflag(target)
    local ifcoutputflag = get_ifcoutputflag(target)
    assert(headerunitflag and headernameflag and exportheaderflag, "compiler(msvc): does not support c++ header units!")

    -- flush job
    local flushjob = batchjobs:addjob(target:name() .. "_user_headerunits_flush_mapper", function(index, total)
        _flush_mapflags_to_mapper(target)
    end, {rootjob = opt.rootjob})

    -- build headerunits
    local common_args = {"-TP", exportheaderflag, "-c"}
    local projectdir = os.projectdir()
    for _, headerunit in ipairs(headerunits) do
        local file = path.relative(headerunit.path, target:scriptdir())
        local objectfile = target:objectfile(file)
        local outputdir
        if headerunit.type == ":quote" then
            outputdir = path.join(cachedir, path.directory(path.relative(headerunit.path, projectdir)))
        else
            -- if path is relative then its a subtarget path
            outputdir = path.join(cachedir, path.is_absolute(headerunit.path) and path.directory(headerunit.path):sub(3) or headerunit.path)
        end
        local bmifilename = path.basename(objectfile) .. get_bmi_extension()
        local bmifile = path.join(outputdir, bmifilename)
        batchjobs:addjob(headerunit.name, function (index, total)
            depend.on_changed(function()
                if not common.localcache():get2(headerunit.name, "building") then 
                    common.localcache():set2(headerunit.name, "building", true)
                    progress.show((index * 100) / total, "${color.build.object}generating.cxx.headerunit.bmi %s", headerunit.name)
                    local objectdir = path.directory(objectfile)
                    if not os.isdir(objectdir) then
                        os.mkdir(objectdir)
                    end
                    if not os.isdir(outputdir) then
                        os.mkdir(outputdir)
                    end

                    -- generate headerunit
                    local args = {headernameflag .. headerunit.type, headerunit.path, ifcoutputflag, outputdir, "/Fo" .. objectfile}
                    os.vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, args), {envs = vcvars})
                    common.localcache():set2(headerunit.name, "building", false)
                end

                _add_module_to_mapper(target, headerunitflag .. headerunit.type, headerunit.name, path.translate(bmifile))
            end, {dependfile = target:dependfile(bmifile), files = {headerunit.path}})
        end, {rootjob = flushjob})
        _add_objectfile_to_link_arguments(target, objectfile)
    end
end

-- generate target user header units for batchcmds
function generate_user_headerunits_for_batchcmds(target, batchcmds, headerunits, opt)
    local compinst = target:compiler("cxx")
    local toolchain = target:toolchain("msvc")
    local vcvars = toolchain:config("vcvars")
    local cachedir = common.modules_cachedir(target)

    -- get flags
    local exportheaderflag = get_exportheaderflag(target)
    local headerunitflag = get_headerunitflag(target)
    local headernameflag = get_headernameflag(target)
    local ifcoutputflag = get_ifcoutputflag(target)
    assert(headerunitflag and headernameflag and exportheaderflag, "compiler(msvc): does not support c++ header units!")

    -- build headerunits
    local common_args = {"-TP", exportheaderflag, "-c"}
    local projectdir = os.projectdir()
    local depmtime = 0
    for _, headerunit in ipairs(headerunits) do
        local file = path.relative(headerunit.path, target:scriptdir())
        local objectfile = target:objectfile(file)
        local outputdir
        if headerunit.type == ":quote" then
            outputdir = path.join(cachedir, path.directory(path.relative(headerunit.path, projectdir)))
        else
            -- if path is relative then its a subtarget path
            outputdir = path.join(cachedir, path.is_absolute(headerunit.path) and path.directory(headerunit.path):sub(3) or headerunit.path)
        end
        batchcmds:mkdir(outputdir)

        local bmifilename = path.basename(objectfile) .. get_bmi_extension()
        local bmifile = path.join(outputdir, bmifilename)
        batchcmds:mkdir(path.directory(objectfile))

        local args = {headernameflag .. headerunit.type, headerunit.path, ifcoutputflag, outputdir, "/Fo" .. objectfile}

        batchcmds:show_progress(opt.progress, "${color.build.object}generating.cxx.headerunit.bmi %s", headerunit.name)
        batchcmds:vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, args), {envs = vcvars})
        batchcmds:add_depfiles(headerunit.path)

        _add_module_to_mapper(target, headerunitflag .. headerunit.type, headerunit.name, path.translate(bmifile))
        _add_objectfile_to_link_arguments(target, objectfile)

        depmtime = math.max(depmtime, os.mtime(bmifile))
    end
    batchcmds:set_depmtime(depmtime)
    _flush_mapflags_to_mapper(target)
end

-- build module files for batchjobs
function build_modules_for_batchjobs(target, batchjobs, objectfiles, modules, opt)
    local compinst = target:compiler("cxx")
    local toolchain = target:toolchain("msvc")
    local vcvars = toolchain:config("vcvars")
    local cachedir = common.modules_cachedir(target)

    -- get flags
    local ifcoutputflag = get_ifcoutputflag(target)
    local interfaceflag = get_interfaceflag(target)
    local referenceflag = get_referenceflag(target)

    -- flush job
    local flushjob = batchjobs:addjob(target:name() .. "_modules", function(index, total)
        _flush_mapflags_to_mapper(target)
    end, {rootjob = opt.rootjob})

    -- build modules
    local common_args = {"-TP"}
    local provided_modules = {}
    for _, objectfile in ipairs(objectfiles) do
        local m = modules[objectfile]
        if m and m.provides then
            -- assume there that provides is only one, until we encounter the case
            local length = 0
            local name, provide
            for k, v in pairs(m.provides) do
                length = length + 1
                name = k
                provide = v
                if length > 1 then
                    raise("multiple provides are not supported now!")
                end
            end

            local bmifile = provide.bmi
            local moduleinfo = table.copy(provide)
            moduleinfo.job = batchjobs:newjob(provide.sourcefile, function (index, total)
                depend.on_changed(function()
                    progress.show((index * 100) / total, "${color.build.object}generating.cxx.module.bmi %s", name)
                    local objectdir = path.directory(objectfile)
                    if not os.isdir(objectdir) then
                        os.mkdir(objectdir)
                    end
                    -- append module mapper flags first
                    -- @note we add it at the end to ensure that the full mapflags are already stored in the mapper
                    if not target:data("cxx.add_modules_mapflags") then
                        -- append target module mapper flags
                        local mapflags = _get_mapflags_from_mapper(target)
                        if mapflags then
                            target:add("cxxflags", mapflags, {force = true})
                        end

                        -- append deps module mapper flags
                        for _, dep in ipairs(target:orderdeps()) do
                            local mapflags = _get_mapflags_from_mapper(dep)
                            if mapflags then
                                target:add("cxxflags", mapflags, {force = true})
                            end
                        end

                        target:data_set("cxx.add_modules_mapflags", true)
                    end
                    local args = {"-c", "-Fo" .. objectfile, interfaceflag, ifcoutputflag, bmifile, provide.sourcefile}
                    os.vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, args), {envs = vcvars})
                end, {dependfile = target:dependfile(bmifile), files = {provide.sourcefile}})
                local flag = name .. "=" .. path.translate(bmifile)
                _add_module_to_mapper(target, referenceflag, name, path.translate(bmifile))
                target:add("cxxflags", {referenceflag, flag}, {force = true, expand = false})
            end)
            if m.requires then
                moduleinfo.deps = table.keys(m.requires)
            end
            moduleinfo.name = name
            provided_modules[name] = moduleinfo
            target:add("objectfiles", objectfile)
        end
    end

    -- build batchjobs for modules
    common.build_batchjobs_for_modules(provided_modules, batchjobs, flushjob)
end

-- build module files for batchcmds
function build_modules_for_batchcmds(target, batchcmds, objectfiles, modules, opt)
    local compinst = target:compiler("cxx")
    local toolchain = target:toolchain("msvc")
    local vcvars = toolchain:config("vcvars")
    local cachedir = common.modules_cachedir(target)

    -- get flags
    local ifcoutputflag = get_ifcoutputflag(target)
    local interfaceflag = get_interfaceflag(target)
    local referenceflag = get_referenceflag(target)

    -- make sure mapper is flushed
    _flush_mapflags_to_mapper(target)

    -- append target module mapper flags
    local mapflags = _get_mapflags_from_mapper(target)
    if mapflags then
        target:add("cxxflags", mapflags, {force = true})
    end

    -- append deps module mapper flags
    for _, dep in ipairs(target:orderdeps()) do
        local mapflags = _get_mapflags_from_mapper(dep)
        if mapflags then
            target:add("cxxflags", mapflags, {force = true})
        end
    end

    -- build modules
    local common_args = {"-TP"}
    local depmtime = 0
    for _, objectfile in ipairs(objectfiles) do
        local m = modules[objectfile]
        if m and m.provides then
            local name, provide
            for k, v in pairs(m.provides) do
                name = k
                provide = v
                break
            end

            local bmifile = provide.bmi
            local args = {"-c", "-Fo" .. objectfile, interfaceflag, ifcoutputflag, bmifile, provide.sourcefile}
            batchcmds:show_progress(opt.progress, "${color.build.object}generating.cxx.module.bmi %s", name)
            batchcmds:mkdir(path.directory(objectfile))
            batchcmds:vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, args), {envs = vcvars})
            batchcmds:add_depfiles(provide.sourcefile)
            local flag = name .. "=" .. bmifile
            _add_module_to_mapper(target, referenceflag, name, bmifile)
            target:add("cxxflags", {referenceflag, flag}, {force = true, expand = false})
            depmtime = math.max(depmtime, os.mtime(bmifile))
        end
    end
    batchcmds:set_depmtime(depmtime)
    _flush_mapflags_to_mapper(target)
end

function get_bmi_extension()
    return ".ifc"
end

function get_modulesflag(target)
    local modulesflag = _g.modulesflag
    if modulesflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-experimental:module", "cxxflags", {flagskey = "cl_experimental_module"}) then
            modulesflag = "-experimental:module"
        end
        assert(modulesflag, "compiler(msvc): does not support c++ module!")
        _g.modulesflag = modulesflag or false
    end
    return modulesflag or nil
end

function get_ifcoutputflag(target)
    local ifcoutputflag = _g.ifcoutputflag
    if ifcoutputflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-ifcOutput", "cxxflags", {flagskey = "cl_ifc_output"})  then
            ifcoutputflag = "-ifcOutput"
        end
        assert(ifcoutputflag, "compiler(msvc): does not support c++ module!")
        _g.ifcoutputflag = ifcoutputflag or false
    end
    return ifcoutputflag or nil
end

function get_ifcsearchdirflag(target)
    local ifcsearchdirflag = _g.ifcsearchdirflag
    if ifcsearchdirflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-ifcSearchDir", "cxxflags", {flagskey = "cl_ifc_search_dir"})  then
            ifcsearchdirflag = "-ifcSearchDir"
        end
        assert(ifcsearchdirflag, "compiler(msvc): does not support c++ module!")
        _g.ifcsearchdirflag = ifcsearchdirflag or false
    end
    return ifcsearchdirflag or nil
end

function get_interfaceflag(target)
    local interfaceflag = _g.interfaceflag
    if interfaceflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-interface", "cxxflags", {flagskey = "cl_interface"}) then
            interfaceflag = "-interface"
        end
        assert(interfaceflag, "compiler(msvc): does not support c++ module!")
        _g.interfaceflag = interfaceflag or false
    end
    return interfaceflag
end

function get_referenceflag(target)
    local referenceflag = _g.referenceflag
    if referenceflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-reference", "cxxflags", {flagskey = "cl_reference"}) then
            referenceflag = "-reference"
        end
        assert(referenceflag, "compiler(msvc): does not support c++ module!")
        _g.referenceflag = referenceflag or false
    end
    return referenceflag or nil
end

function get_headernameflag(target)
    local headernameflag = _g.headernameflag
    if headernameflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-headerName:quote", "cxxflags", {flagskey = "cl_header_name_quote"}) and
        compinst:has_flags("-headerName:angle", "cxxflags", {flagskey = "cl_header_name_angle"}) then
            headernameflag = "-headerName"
        end
        _g.headernameflag = headernameflag or false
    end
    return headernameflag or nil
end

function get_headerunitflag(target)
    local headerunitflag = _g.headerunitflag
    if headerunitflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-headerUnit:quote", "cxxflags", {flagskey = "cl_header_unit_quote"}) and
        compinst:has_flags("-headerUnit:angle", "cxxflags", {flagskey = "cl_header_unit_angle"}) then
            headerunitflag = "-headerUnit"
        end
        _g.headerunitflag = headerunitflag or false
    end
    return headerunitflag or nil
end

function get_exportheaderflag(target)
    local modulesflag = get_modulesflag(target)
    local exportheaderflag = _g.exportheaderflag
    if exportheaderflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags(modulesflag .. " -exportHeader", "cxxflags", {flagskey = "cl_export_header"}) then
            exportheaderflag = "-exportHeader"
        end
        _g.exportheaderflag = exportheaderflag or false
    end
    return exportheaderflag or nil
end

function get_stdifcdirflag(target)
    local stdifcdirflag = _g.stdifcdirflag
    if stdifcdirflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-stdIfcDir", "cxxflags", {flagskey = "cl_std_ifc_dir"}) then
            stdifcdirflag = "-stdIfcDir"
        end
        _g.stdifcdirflag = stdifcdirflag or false
    end
    return stdifcdirflag or nil
end

function get_scandependenciesflag(target)
    local scandependenciesflag = _g.scandependenciesflag
    if scandependenciesflag == nil then
        local compinst = target:compiler("cxx")
        local scan_dependencies_jsonfile = os.tmpfile() .. ".json"
        if compinst:has_flags("-scanDependencies " .. scan_dependencies_jsonfile, "cxflags", {flagskey = "cl_scan_dependencies",
            on_check = function (ok, errors)
                if os.isfile(scan_dependencies_jsonfile) then
                    ok = true
                end
                if ok and not os.isfile(scan_dependencies_jsonfile) then
                    ok = false
                end
                return ok, errors
            end}) then
            scandependenciesflag = "-scanDependencies"
        end
        _g.scandependenciesflag = scandependenciesflag or false
    end
    return scandependenciesflag or nil
end
