-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2010 Jeff Mitchell
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local max = math.max;

local getAuthenticationDatabaseSHA1 = require "util.sasl.scram".getAuthenticationDatabaseSHA1;
local usermanager = require "core.usermanager";
local generate_uuid = require "util.uuid".generate;
local new_sasl = require "util.sasl".new;
local hex = require"util.hex";
local to_hex, from_hex = hex.to, hex.from;

local log = module._log;
local host = module.host;

local accounts = module:open_store("accounts");



-- Default; can be set per-user
local default_iteration_count = 4096;

-- define auth provider
local provider = {};

function provider.test_password(username, password)
	log("debug", "test password for user '%s'", username);
	local credentials = accounts:get(username) or {};

	if credentials.password ~= nil and string.len(credentials.password) ~= 0 then
		if credentials.password ~= password then
			return nil, "Auth failed. Provided password is incorrect.";
		end

		if provider.set_password(username, credentials.password) == nil then
			return nil, "Auth failed. Could not set hashed password from plaintext.";
		else
			return true;
		end
	end

	if credentials.iteration_count == nil or credentials.salt == nil or string.len(credentials.salt) == 0 then
		return nil, "Auth failed. Stored salt and iteration count information is not complete.";
	end

	local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, credentials.salt, credentials.iteration_count);

	local stored_key_hex = to_hex(stored_key);
	local server_key_hex = to_hex(server_key);

	if valid and stored_key_hex == credentials.stored_key and server_key_hex == credentials.server_key then
		return true;
	else
		return nil, "Auth failed. Invalid username, password, or password hash information.";
	end
end

function provider.set_password(username, password)
	log("debug", "set_password for username '%s'", username);
	local account = accounts:get(username);
	if account then
		account.salt = generate_uuid();
		account.iteration_count = max(account.iteration_count or 0, default_iteration_count);
		local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, account.salt, account.iteration_count);
		local stored_key_hex = to_hex(stored_key);
		local server_key_hex = to_hex(server_key);

		account.stored_key = stored_key_hex
		account.server_key = server_key_hex

		account.password = nil;
		return accounts:set(username, account);
	end
	return nil, "Account not available.";
end

function provider.user_exists(username)
	local account = accounts:get(username);
	if not account then
		log("debug", "account not found for username '%s'", username);
		return nil, "Auth failed. Invalid username";
	end
	return true;
end

function provider.users()
	return accounts:users();
end

function provider.create_user(username, password)
	if password == nil then
		return accounts:set(username, {});
	end
	local salt = generate_uuid();
	local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, salt, default_iteration_count);
	local stored_key_hex = to_hex(stored_key);
	local server_key_hex = to_hex(server_key);
	return accounts:set(username, {stored_key = stored_key_hex, server_key = server_key_hex, salt = salt, iteration_count = default_iteration_count});
end

function provider.delete_user(username)
	return accounts:set(username, nil);
end

function provider.get_sasl_handler()
	local testpass_authentication_profile = {
		plain_test = function(sasl, username, password, realm)
			return usermanager.test_password(username, realm, password), true;
		end,
		scram_sha_1 = function(sasl, username, realm)
			local credentials = accounts:get(username);
			if not credentials then return; end
			if credentials.password then
				usermanager.set_password(username, credentials.password, host);
				credentials = accounts:get(username);
				if not credentials then return; end
			end

			local stored_key, server_key, iteration_count, salt = credentials.stored_key, credentials.server_key, credentials.iteration_count, credentials.salt;
			stored_key = stored_key and from_hex(stored_key);
			server_key = server_key and from_hex(server_key);
			return stored_key, server_key, iteration_count, salt, true;
		end
	};
	return new_sasl(host, testpass_authentication_profile);
end

module:provides("auth", provider);

