-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
--

--
-- Custom auth module 
-- 

local datamanager = require "util.datamanager";
local log = require "util.logger".init("auth_custom");
local type = type;
local error = error;
local ipairs = ipairs;
local hashes = require "util.hashes";
local jid_bare = require "util.jid".bare;
local config = require "core.configmanager";
local usermanager = require "core.usermanager";
local new_sasl = require "util.sasl".new;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local hosts = hosts;

local prosody = _G.prosody;

function new_default_provider(host)
	local provider = { name = "custom" };
	log("debug", "initializing custom authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		-- TODO verify with api server 
		return true;
	end

	function provider.user_exists(username)
		return true;
	end

	function provider.get_sasl_handler()
		local testpass_authentication_profile = {
			plain_test = function(sasl, username, password, realm)
				return provider.test_password(username, password), true;
			end,
		};
		return new_sasl(module.host, testpass_authentication_profile);
	end
	
	return provider;
end

module:add_item("auth-provider", new_default_provider(module.host));

