local tonumber = tonumber;
local assert = assert;
local t_insert, t_concat = table.insert, table.concat;
local url_parse = require "socket.url".parse;
local urldecode = require "util.http".urldecode;

local function preprocess_path(path)
	path = urldecode((path:gsub("//+", "/")));
	if path:sub(1,1) ~= "/" then
		path = "/"..path;
	end
	local level = 0;
	for component in path:gmatch("([^/]+)/") do
		if component == ".." then
			level = level - 1;
		elseif component ~= "." then
			level = level + 1;
		end
		if level < 0 then
			return nil;
		end
	end
	return path;
end

local httpstream = {};

function httpstream.new(success_cb, error_cb, parser_type, options_cb)
	local client = true;
	if not parser_type or parser_type == "server" then client = false; else assert(parser_type == "client", "Invalid parser type"); end
	local buf, buflen, buftable = {}, 0, true;
	local bodylimit = tonumber(options_cb and options_cb().body_size_limit) or 10*1024*1024;
	local buflimit = tonumber(options_cb and options_cb().buffer_size_limit) or bodylimit * 2;
	local chunked, chunk_size, chunk_start;
	local state = nil;
	local packet;
	local len;
	local have_body;
	local error;
	return {
		feed = function(_, data)
			if error then return nil, "parse has failed"; end
			if not data then -- EOF
				if buftable then buf, buftable = t_concat(buf), false; end
				if state and client and not len then -- reading client body until EOF
					packet.body = buf;
					success_cb(packet);
				elseif buf ~= "" then -- unexpected EOF
					error = true; return error_cb();
				end
				return;
			end
			if buftable then
				t_insert(buf, data);
			else
				buf = { buf, data };
				buftable = true;
			end
			buflen = buflen + #data;
			if buflen > buflimit then error = true; return error_cb("max-buffer-size-exceeded"); end
			while buflen > 0 do
				if state == nil then -- read request
					if buftable then buf, buftable = t_concat(buf), false; end
					local index = buf:find("\r\n\r\n", nil, true);
					if not index then return; end -- not enough data
					local method, path, httpversion, status_code, reason_phrase;
					local first_line;
					local headers = {};
					for line in buf:sub(1,index+1):gmatch("([^\r\n]+)\r\n") do -- parse request
						if first_line then
							local key, val = line:match("^([^%s:]+): *(.*)$");
							if not key then error = true; return error_cb("invalid-header-line"); end -- TODO handle multi-line and invalid headers
							key = key:lower();
							headers[key] = headers[key] and headers[key]..","..val or val;
						else
							first_line = line;
							if client then
								httpversion, status_code, reason_phrase = line:match("^HTTP/(1%.[01]) (%d%d%d) (.*)$");
								status_code = tonumber(status_code);
								if not status_code then error = true; return error_cb("invalid-status-line"); end
								have_body = not
									 ( (options_cb and options_cb().method == "HEAD")
									or (status_code == 204 or status_code == 304 or status_code == 301)
									or (status_code >= 100 and status_code < 200) );
							else
								method, path, httpversion = line:match("^(%w+) (%S+) HTTP/(1%.[01])$");
								if not method then error = true; return error_cb("invalid-status-line"); end
							end
						end
					end
					if not first_line then error = true; return error_cb("invalid-status-line"); end
					chunked = have_body and headers["transfer-encoding"] == "chunked";
					len = tonumber(headers["content-length"]); -- TODO check for invalid len
					if len and len > bodylimit then error = true; return error_cb("content-length-limit-exceeded"); end
					if client then
						-- FIXME handle '100 Continue' response (by skipping it)
						if not have_body then len = 0; end
						packet = {
							code = status_code;
							httpversion = httpversion;
							headers = headers;
							body = have_body and "" or nil;
							-- COMPAT the properties below are deprecated
							responseversion = httpversion;
							responseheaders = headers;
						};
					else
						local parsed_url;
						if path:byte() == 47 then -- starts with /
							local _path, _query = path:match("([^?]*).?(.*)");
							if _query == "" then _query = nil; end
							parsed_url = { path = _path, query = _query };
						else
							parsed_url = url_parse(path);
							if not(parsed_url and parsed_url.path) then error = true; return error_cb("invalid-url"); end
						end
						path = preprocess_path(parsed_url.path);
						headers.host = parsed_url.host or headers.host;

						len = len or 0;
						packet = {
							method = method;
							url = parsed_url;
							path = path;
							httpversion = httpversion;
							headers = headers;
							body = nil;
						};
					end
					buf = buf:sub(index + 4);
					buflen = #buf;
					state = true;
				end
				if state then -- read body
					if client then
						if chunked then
							if chunk_start and buflen - chunk_start - 2 < chunk_size then
								return;
							end -- not enough data
							if buftable then buf, buftable = t_concat(buf), false; end
							if not buf:find("\r\n", nil, true) then
								return;
							end -- not enough data
							if not chunk_size then
								chunk_size, chunk_start = buf:match("^(%x+)[^\r\n]*\r\n()");
								chunk_size = chunk_size and tonumber(chunk_size, 16);
								if not chunk_size then error = true; return error_cb("invalid-chunk-size"); end
							end
							if chunk_size == 0 and buf:find("\r\n\r\n", chunk_start-2, true) then
								state, chunk_size = nil, nil;
								buf = buf:gsub("^.-\r\n\r\n", ""); -- This ensure extensions and trailers are stripped
								success_cb(packet);
							elseif buflen - chunk_start - 2 >= chunk_size then -- we have a chunk
								packet.body = packet.body..buf:sub(chunk_start, chunk_start + (chunk_size-1));
								buf = buf:sub(chunk_start + chunk_size + 2);
								buflen = buflen - (chunk_start + chunk_size + 2 - 1);
								chunk_size, chunk_start = nil, nil;
							else -- Partial chunk remaining
								break;
							end
						elseif len and buflen >= len then
							if buftable then buf, buftable = t_concat(buf), false; end
							if packet.code == 101 then
								packet.body, buf, buflen, buftable = buf, {}, 0, true;
							else
								packet.body, buf = buf:sub(1, len), buf:sub(len + 1);
								buflen = #buf;
							end
							state = nil; success_cb(packet);
						else
							break;
						end
					elseif buflen >= len then
						if buftable then buf, buftable = t_concat(buf), false; end
						packet.body, buf = buf:sub(1, len), buf:sub(len + 1);
						buflen = #buf;
						state = nil; success_cb(packet);
					else
						break;
					end
				end
			end
		end;
	};
end

return httpstream;
