local ropeModule = require('EmbeddedModLoader/injecting/Crop/rope')
local regex = require("EmbeddedModLoader/dataHandling/LuaRegex/Regexp")

local faker = require("EmbeddedModLoader/files/fakeLuaFile")
local sharedFunctions = require("EmbeddedModLoader/injecting/patterns/SharedMethods")

local methods = {}
local offset = 0

-- Function to create a new patch object
function methods.new(patch)
    -- Create a new table to hold the patch data and ensure Options is initialized
    local patchData = {
        Options = {},
        -- Copy other fields from the patch parameter
    }
    for k, v in pairs(patch) do
        patchData[k] = v
    end

    -- Set the metatable for patchData to enable method lookups
    setmetatable(patchData, { __index = methods })

    return patchData
end

local wordLetters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890_"
local function isWordLetter(str)
    local letter = string.sub(str, 1, 1)

    for i = 1, #wordLetters do
        if string.sub(wordLetters, i, i) == letter then
            return true
        end
    end

    return false
end

-- Function to split a string inclusively by a delimiter
local function split_inclusive(str, delimiter)
    local result = {}
    local pattern = "(.-" .. delimiter .. ")"
    local last_end = 1

    for part, end_idx in str:gmatch(pattern .. "()") do
        table.insert(result, part)
        last_end = end_idx
    end

    -- Add the remaining part of the string after the last delimiter
    if last_end <= #str then
        table.insert(result, str:sub(last_end))
    end

    return result
end


local function parse_ref(ref, get_index_by_name)
    if tonumber(ref) ~= nil and ref:match('^%d+$') then
        return tonumber(ref)
    else
        return get_index_by_name(ref)
    end
end



-- regex interpolate::string
function interpolate_string(input_str, get_group, get_index, groups)
    local gsubsList = {}
    local recording = false
    local groupRecording = ""
    local offset = 0

    if not input_str then
        return input_str
    end

    for i = 1, #input_str do
        local ltr = string.sub(input_str, i, i)

        if recording then
            -- find and replace!!!
            -- not isWordLetter(ltr)
            if ltr == " " or ltr == "\t" or ltr == "\n" or ltr == ")" or ltr == "(" or ltr == "]"
                    or ltr == "[" or ltr == "{" or ltr == "}" or ltr == "'" or ltr == '"' or i == #input_str then
                recording = false

                if i == #input_str and not (ltr == " " or ltr == "\t" or ltr == "\n" or ltr == ")" or ltr == "(" or ltr == "]"
                        or ltr == "[" or ltr == "{" or ltr == "}" or ltr == "'" or ltr == '"') then
                    groupRecording = groupRecording .. ltr
                end

                if #groupRecording < 1 then
                    print("SPECIAL CASE ENCOUNTERED!!!!") -- EX: localize('$')..format_ui_value(config.dollars)

                    -- this is innaccurate behavior i beliebe.
                    table.insert(gsubsList, { groupRecording, "" })
                    groupRecording = ""
                    goto continue
                end

                -- get the data from the group and gsub it!!!
                print(groupRecording)
                print(get_index(groupRecording))
                print(get_group(groupRecording))

                local groupReplaceWith = groups.match:groupdict()[groupRecording]
                        or groups.match:grouparr()[tonumber(groupRecording)]

                print(groupReplaceWith)

                -- gsub after search
                offset = offset + #groupRecording + 1
                table.insert(gsubsList, { "$" .. groupRecording, groupReplaceWith })

                groupRecording = ""
                goto continue
            end

            groupRecording = groupRecording .. ltr
            goto continue
        end

        -- start recording
        if ltr == "$" then
            recording = true
        end

        ::continue::
    end

    -- searching is done, gsub time!!!
    for _, data in pairs(gsubsList) do
        if data[1] ~= "$indent" then
            print(data[1], data[2])
            input_str = string.gsub(input_str, data[1], data[2])
        end
    end

    return input_str, offset
end




--target, rope, path (i dont believe any of these are needed because of my implementation)
function methods:apply(target)
    -- inject into this target.
    -- fix pattern
    offset = 0
    self.pattern = sharedFunctions.parseString(self.pattern)

    local fakeLuaFile = faker.RequestDynamicFile(target)
    local source = fakeLuaFile.getSource()
    local rope = ropeModule.new(source)

    -- add to flags, CRLF should always be on by default.
    local flags = "m"
    if self.verbose then
        flags = flags .. 'x'
    end

    --print(self.pattern, flags)
    local newRegex = regex(self.pattern, flags)
    local captures = newRegex:exec(source)

    local path = path or self.target

    if captures == nil or #captures < 0 then
        print("Regex '" .. self.pattern .. "' on target '" .. target .. "' for regex patch from ".. path .. " resulted in no matches");
        return false
    end

    local times = self.times or nil
    if times then
        function warn_regex_mismatch(pattern, target, found_matches, wanted_matches, path)
            -- it really doesnt matter if i have the check here
            print("Regex '''\n".. pattern .. "''' on target '" .. target .. "' for regex patch from " .. path .. " resulted in ".. found_matches .. " matches, wanted " .. wanted_matches)
        end

        if #captures < times then
            warn_regex_mismatch(self.pattern, target, #captures, times, path);
        end

        if #captures > times then
            warn_regex_mismatch(self.pattern, target, #captures, times, path);
            print("Ignoring excess matches")

            -- remove stuff from captures
            for i = 1, times do
                captures[#captures] = nil
            end
        end
    end

    -- This is our running byte offset. We use this to ensure that byte references
    -- within the capture group remain valid even after the rope has been mutated.

    -- i dont believe this matters as we re-load the file each time this method is called
    -- ALTHOUGH it has been kept here because it will be very useful to keep if i need to optimize this
    -- later down the road.

    local delta = 0


    --for i, groups in pairs(captures) do
    -- Get the entire captured span (index 0);
    local groups = captures
    local base = groups.get_group(0).unwrap();

    local base_start = base.start + delta
    local base_end = base['end'] + delta

    -- is rope even needed???
    local base_str = rope:byte_slice(base_start, base_end);

    -- Interpolate capture groups into self.line_prepend, if any capture groups exist within.
    --local line_prepend = ""
    -- might error if we dont even have a line_prepend
    local line_prepend

    -- Example call to interpolate_string
    self.line_prepend = interpolate_string(
            self.line_prepend,
            function(index)
                local span = groups.get_group(index).unwrap()
                if span then
                    return span.start, span.end_
                else
                    return nil, nil
                end
            end,
            function(name)
                local pid = groups.pattern
                return groups.get_group_by_name(name) --0--groups.group_info().to_index(pid, name)
            end,
            groups
    )

    print(self.line_prepend)
    print(self.line_prepend)
    print(self.line_prepend)
    print(self.line_prepend)
    print(self.line_prepend)
    print(self.line_prepend)
    print(self.line_prepend)


    self.root_capture = self.root_capture or "$0"
    -- Cleanup and convert the specified root capture to a span.
    local group_name = string.gsub(self.root_capture, "$", "")
    local target_group = (groups.get_group_by_name(group_name) and groups.get_group_by_name(group_name).unwrap()) or
            groups.get_group(idx) and groups.get_group(idx).unwrap()


    local target_start = (target_group.start + delta);
    local target_end = (target_group['end'] + delta);

    print(target_start)

    -- Example usage
    local payload = self.payload  -- Assuming self.payload is defined
    local line_prepend = self.line_prepend  -- Assuming line_prepend is defined

    -- Split the payload inclusively by newline
    local lines = split_inclusive(payload, "\n")
    local new_payload = table.concat(lines, line_prepend)
    new_payload = (line_prepend or "") .. new_payload

    --print(new_payload)

    payload = interpolate_string(
            payload,
            function(index)
                local span = groups.get_group(index).unwrap()
                if span then
                    return span.start, span.end_
                else
                    return nil, nil
                end
            end,
            function(name)
                local pid = groups.pattern
                return groups.get_group_by_name(name)--0--groups.group_info().to_index(pid, name)
            end,
            groups
    )

    print(payload)

    -- If left border of insertion is a wordchar -> non-wordchar
    -- boundary and our patch starts with a wordchar, prepend space so
    -- it doesn't unintentionally concatenate with characters to its
    -- left to create a larger identifier.

    local bool1 = false
    local bool2 = false

    if isWordLetter(payload) then
        local pre_pt = self.position == "after" and target_end or target_start

        bool1 = true

        if pre_pt > 0 then
            local byte_on_left = rope:byte(pre_pt - 1);
            if isWordLetter(byte_on_left) then
                payload = ' ' .. payload
            end
        end
    end

    if isWordLetter(payload, true) then
        local post_pt = self.position == "before" and target_start or target_end

        bool2 = true

        if post_pt < #rope:to_string() then
            local byte_on_right = rope:byte(post_pt + 1);
            if isWordLetter(byte_on_right) then
                payload = payload .. ' '
            end
        end
    end


    -- match
    if self.position == "before" then
        print(bool1)
        print(bool2)

        rope:insert(target_start, payload) --  - #groups.groups[0] - #(groups.groups[1] or "")
        local new_len = #payload
        --delta += new_len as isize

    elseif self.position == "after" then
        rope:insert(target_end + 1, payload)
        local new_len = #payload--.len()
        --delta += new_len as isize

    elseif self.position == "at" then
        rope:delete(target_start, target_end);
        rope:insert(target_start, payload);
        --local old_len = target_group['end'] - target_group.start;
        --local new_len = #payload;
        --delta -= old_len as isize;
        --delta += new_len as isize;

    end


    fakeLuaFile.setSource(rope:to_string())

    --end
end
















return methods
