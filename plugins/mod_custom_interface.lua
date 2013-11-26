--
-- Prosody Custom interface for messaging to use prosody as proxy to existing messaging systems / apis.
-- Copyright (C) 2013 Marek Vavrecan
--
-- Modules to disable in prior to use this interface correctly: 
-- offline, roster, vcard - no storage needed 
--
-- Outgoing messages will be post to your api url http://localhost/msg [api_url_outgoing_message]
-- Get roster list request will read your api url http://localhost/roster [api_url_roster]
-- Incomming messages should be post from your api to prosody http listener http://localhost:5280/msg 
--
module:depends"http"

local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local jid_prep = require "util.jid".prep;
local json = require "util.json";
local msg = require "util.stanza".message;
local st = require "util.stanza";
local test_password = require "core.usermanager".test_password;
local b64_decode = require "util.encodings".base64.decode;
local formdecode = require "net.http".formdecode;
local formencode = require "net.http".formencode;
local http_request = require "socket.http"; 

-- api of handling server
local api_url_outgoing_message = "http://localhost/msg"; 
local api_url_roster = "http://localhost/roster";

-- calculate signature for string, used for request verification
-- TODO hash against message data 
local function get_signature() 
	return "secret";
end

-- messages received 
--[[
	example:
	curl 
		http://localhost:5280/msg/ 
		-H "Content-Type: application/x-www-form-urlencoded" 
		-d "from=marek@localhost&to=marek2@localhost&body=hello&signature=secret"
]]--
local function handle_incoming(event, path)
	local request = event.request;
	local response = event.response;
	local headers = request.headers;

	if headers.content_type ~= "application/x-www-form-urlencoded" then 
		return 500; 
	end

	local post_body = formdecode(request.body);
	local to = post_body.to;
	local from = post_body.from;
	local body = post_body.body;
	local signature = get_signature();

	-- check signature
	if signature ~= post_body.signature then
		return 401;
	end

	-- check if active session exists and do not deliver is user if not connected
    local to_user, to_host = jid_split(to);
	if hosts[to_host] == nil or hosts[to_host].sessions[to_user] == nil then 
		return 201; 
	end

	-- deliver message
	module:log("debug", "Incomming message %s to %s with body %s", from, to, body);
	module:send(msg({ to = to, from = from, type = "chat"}, body));

	return 201;
end

-- set listener for incomming messages
module:provides("http", {
	default_path = "/msg";
	route = {
		["POST /*"] = handle_incoming;
		OPTIONS = function(e)
			local headers = e.response.headers;
			headers.allow = "POST";
			headers.accept = "application/x-www-form-urlencoded, text/plain";
			return 200;
		end;
	}
});

-- outgoing messages that will be post to custom url
-- post variables: from, to, body, signature
local function handle_outgoing(event)
	local origin, stanza = event.origin, event.stanza;
	local message_type = stanza.attr.type;
	
	if message_type == "error" or message_type == "groupchat" then return; end	
	local from, to = jid_bare(stanza.attr.from), jid_bare(stanza.attr.to);
	local body = stanza:get_child("body");

	if not body then
		return; 
	end

	body = body:get_text();
	local signature = get_signature();

	module:log("debug", "Outgoing message %s to %s with body %s", from, to, body); 

	-- http request call
	local request_body = formencode({from = from, to = to, body = body, signature = signature});
	local response_body = {};
	local response, code, response_headers = http_request.request{
		url = api_url_outgoing_message,
		method = "POST";
		headers = 
		{
			["Connection"] = "close";
			["Content-Type"] = "application/x-www-form-urlencoded";
			["Content-Length"] = #request_body;
		};
		source = ltn12.source.string(request_body);
		sink = ltn12.sink.table(response_body);
	};

	-- sending failed 
	if response == nil then
		module:log("debug", "Call failed %s", tostring(code));
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable", "Error sending message"));
		module:send(msg({ to = from, from = to, type = "chat"}, "Error sending message: " .. tostring(code)));
		return true;
	end

	-- TODO verify response_body
	module:log("debug", "Call response %s %s %s", tostring(response), tostring(code), tostring(response_headers));
	return nil;
end

module:hook("pre-message/bare", handle_outgoing, 1000);
module:hook("pre-message/full", handle_outgoing, 1000);

-- read only roster (user list) - requested from custom url
-- json list with objects containg jid and name
local function handle_roster(event)
	local session, stanza = event.origin, event.stanza;

	if stanza.attr.type == "get" then
		local roster = st.reply(stanza);
		local from = jid_bare(stanza.attr.from);
		roster:query("jabber:iq:roster");

		-- receive roster from api
		local signature = get_signature();
		local request_body = formencode({from = from, signature = signature});
		local response_body = {};
		local response, code, response_headers = http_request.request{
			url = api_url_roster,
			method = "POST";
			headers = 
			{
				["Connection"] = "close";
				["Content-Type"] = "application/x-www-form-urlencoded";
				["Content-Length"] = #request_body;
			};
			source = ltn12.source.string(request_body);
			sink = ltn12.sink.table(response_body);
		};

		if (response ~= nil) then
			-- create roster list from json response
			local list = json.decode(table.concat(response_body));
			for i = 1, #list do
				roster:tag("item", {
					jid = list[i].jid,
					subscription = "both",
					ask = nil,
					name = list[i].name,
				});
				roster:up();
			end
		end

		session.send(roster);
		session.interested = false; -- readonly, not interested in changes
	end
	return true;
end

local function add_roster_support(event)
	local origin, features = event.origin, event.features;
	local rosterver_stream_feature = st.stanza("ver", {xmlns="urn:xmpp:features:rosterver"});
	if origin.username then
		features:add_child(rosterver_stream_feature);
	end
end

module:add_feature("jabber:iq:roster");

module:hook("stream-features", add_roster_support, 1O00);
module:hook("iq/self/jabber:iq:roster:query", handle_roster, 1000);

