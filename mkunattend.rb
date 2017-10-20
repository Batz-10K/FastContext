#!/usr/bin/ruby

# Copyright (c) 2017 BlackBerry.  All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Faster context mechanism for windows.
# This works by populating an Unattend.xml file with the VM parameters for sysprep to read when the VM starts.
# This eliminates up to two reboots due to the fact that the VM will come up with the correct hostname and can join the domain if required during
# the initial sysprep specialize pass.
#
# Author: Paul Batchelor, 27-Jul-2016
#
$LOAD_PATH << "/usr/lib/one/ruby"
ENV["ONE_XMLRPC"] = "http://opennebula-server:2633/RPC2"
require 'OpenNebula'
require 'nokogiri'
require 'ipaddr'
require 'cgi'
include OpenNebula

cgi = CGI.new

params=cgi.path_info
ourvmid=params.split("/")[1]
userid =params.split("/")[2]
passwd =params.split("/")[3]

creds = userid + ":" + passwd
# Connect to OpenNebula and read our VM info
client = Client.new(creds,@proxy)
thisvm = VirtualMachine.new(VirtualMachine.build_xml(ourvmid),client)
rc = thisvm.info
if OpenNebula.is_error?(rc)
  puts rc.message
  exit -1
end

# In order to generate an Unattend.xml we need to identify the VM as running Windows. This is done with a tag on the template
is_windows = thisvm["TEMPLATE/CONTEXT/WINDOWS"]

if is_windows != nil then
  newhostname = thisvm["TEMPLATE/CONTEXT/SET_HOSTNAME"]
  newip       = thisvm["TEMPLATE/CONTEXT/ETH0_IP"]
  newmask     = thisvm["TEMPLATE/CONTEXT/ETH0_MASK"]
  macaddress  = thisvm["TEMPLATE/CONTEXT/ETH0_MAC"]
  gateway     = thisvm["TEMPLATE/CONTEXT/ETH0_GATEWAY"]
  dnsservers  = thisvm["TEMPLATE/CONTEXT/ETH0_DNS"]
  dnsdomain   = thisvm["TEMPLATE/CONTEXT/DOMAIN"]
  addomain    = thisvm["TEMPLATE/CONTEXT/ADDOMAIN"]
  aduser      = thisvm["TEMPLATE/CONTEXT/ADUSER"]
  adpw        = thisvm["TEMPLATE/CONTEXT/ADPW"]
  adou        = thisvm["TEMPLATE/CONTEXT/ADOU"]

# Fetch our template Unattend.xml, and grab the proper nodes
  doc                     = File.open("Unattend-template.xml") { |f| Nokogiri::XML(f) }
  hostnamenode            = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-Shell-Setup"]/xmlns:ComputerName')
  ipaddressnode           = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-TCPIP"]/xmlns:Interfaces/xmlns:Interface/xmlns:UnicastIpAddresses/xmlns:IpAddress')
  gwnode                  = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-TCPIP"]/xmlns:Interfaces/xmlns:Interface/xmlns:Routes/xmlns:Route/xmlns:NextHopAddress')
  adapterid               = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-TCPIP"]/xmlns:Interfaces/xmlns:Interface/xmlns:Identifier')
  dnsservernodeid         = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-DNS-Client"]/xmlns:Interfaces/xmlns:Interface/xmlns:Identifier')
  dnsservernodednsserver1 = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-DNS-Client"]/xmlns:Interfaces/xmlns:Interface/xmlns:DNSServerSearchOrder/xmlns:IpAddress[1]')
  dnsservernodednsserver2 = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-DNS-Client"]/xmlns:Interfaces/xmlns:Interface/xmlns:DNSServerSearchOrder/xmlns:IpAddress[2]')
  dnsdomainnode           = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-DNS-Client"]/xmlns:DNSDomain')
  join_addomain           = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-UnattendedJoin"]/xmlns:Identification/xmlns:JoinDomain')
  join_aduserdom          = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-UnattendedJoin"]/xmlns:Identification/xmlns:Credentials/xmlns:Domain')
  join_aduser             = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-UnattendedJoin"]/xmlns:Identification/xmlns:Credentials/xmlns:Username')
  join_adpw               = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-UnattendedJoin"]/xmlns:Identification/xmlns:Credentials/xmlns:Password')
  join_adou               = doc.at_xpath('//xmlns:unattend/xmlns:settings[@pass="specialize"]/xmlns:component[@name="Microsoft-Windows-UnattendedJoin"]/xmlns:Identification/xmlns:MachineObjectOU')

# Populate the Unattend.xml with our VM parameters
  hostnamenode.content            = newhostname
  cidrmask                        = IPAddr.new(newmask).to_i.to_s(2).count("1") # Convert from the OpenNebula standard notation for subnet mask dotted-decimal (e.g. 255.255.255.0)
  newaddress                      = newip.to_s + "/" + cidrmask.to_s            # to CIDR notation (e.g. /24)
  ipaddressnode.content           = newaddress
  gwnode.content                  = gateway
  adapterid.content               = macaddress.gsub(/:/, '-')
  dnsservernodeid.content         = macaddress.gsub(/:/, '-')
  dnsservernodednsserver1.content = dnsservers.split(" ")[0]
  dnsservernodednsserver2.content = dnsservers.split(" ")[1]
  dnsdomainnode.content           = dnsdomain

# If an AD domain is specified, join it.
  if addomain != nil then
    join_addomain.content  = addomain
    join_aduserdom.content = addomain
    join_aduser.content    = aduser
    join_adpw.content      = adpw
    if adou != nil then
      join_adou.content    = adou 
    end
  end

# Write out our populated unattend.xml
  xml = doc.to_s

# for invocation from a webserver, write populated xml to stdout

  cgi.out("status" => "OK", "type" => "text/plain", "connection" => "close") do
    xml
  end

end
