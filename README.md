## Improving OpenNebula contextualization for Windows

### Overview

There are a number of issues with the current mechanisms for contextualizing windows in OpenNebula. These include, but are not limited to:

* The context.ps1 script needs to be either referenced in the VM template, or included in the image. If it is referenced in the template, it's easy to include a bad link, or not include it at all (which results in a broken vm). If the context script is included in the image, then it's hard to update without updating the entire image.
* Setting the hostname requires a reboot on Windows. This takes time
* Joining a domain requires a reboot. This also takes time. 
* Automating domain joins and host renames is difficult as script state must be managed across multiple reboots. Some mechanisms for triggering scripts at boot up get broken when the VM joins a domain (e.g. Scheduled Tasks)
* Multiple reboots at VM startup is *slow* and requires many iops.
* There are a number of issues with Cloud-Init (particularly: poor OpenNebula support)

### There must be a better way

This is a test to see if it is possible to use Windows' __native__ methods for contextualization. Namely, Unattend.xml. This would allow a VM to be fully contextualized at startup as part of the sysprep 'specialize' pass where the VM is configured for the current hypervisor, sids and guids are regenerated, etc. At the time that any user startup scripts run, the VM would be fully operational, network configured, correct hostname applied, and already joined to the domain (if required). No reboots pending. 

#### There are a couple of issues that must be solved first. These are:

1. Is it possible to have setup.exe (the component that does the sysprep specialize pass) search for an Unattend.xml file somewhere on the context iso or mounted volume?
2. We have a chicken-and-egg problem. Unattend.xml needs to be fully populated before the VM starts, but we can't do it at the time we build the image, as we can't know the parameters that the user intends to use (e.g. hostname/network, etc) until just before the VM starts.

#### Possible solutions:

1. setup.exe can be configured to search for an Unattend.xml file on the context iso. Happily, setup will search a number of locations for Unattend.xml files, so this means that we can configure a search for an Unattend.xml file on the context iso, and safely continue if one is not present (setup will use the copy that is placed in the Windows directory by sysprep). This, however has the effect of forcing a certain disk configuration on the VM. (the context drive must be mounted on a fixed path, in this case D:\). Unfortunately 
2. There aren't any good methods for this. Ideally we should be able to call a script at VM startup from our template that places a file (In this case, Unattend.xml) on the context iso as the context iso is being built, but after all of the VM configuration/metadata has been set up. In the meantime, we use an external web server to populate a template Unattend.xml with the parameters for the VM being called. (The cgi script on the web server will call into the opennebula ruby api to retrieve the network and other parameters for the booting VM. May not work under high load conditions) 

#### Results

The VM template was updated to call an external cgi script to generate the proper Unattend.xml, and have it placed on the context iso. The booting VM searches for Unattend.xml and reads, then applies the configuration parameters as part of the sysprep specialize pass. The VM reboots once and comes up fully configured. Timings were taking comparing Unattend.xml vs the traditional context.ps1 startup.

| Test | Result | Comment |
| ---- | ------ | ------- |
|Image build 48 using Unattend.xml context | 3:30 to useable | (able to accept RDP logins of domain accounts, no further reboots required) |
|Image build 48 using context.ps1 context  | 7.00 to useable | (incl 2 reboots + manual domain join as there isn't an automated method for doing this at the moment) |

It would be possible to improve these boot times by going to a fixed hardware configuration and eliminating the driver probe/reinstall phase of setup at the initial boot.

### How-To set up the windows image

1. On your windows image, after you have configured it, run the sysprep generalize command, but do not shut down the VM after running sysprep. 
2. Run the SetUnattendPath.ps1 script. (optionally update the path set in this script if you use a different drive letter than D: for your context iso)
3. Shut down the VM.

This will configure Windows setup (the component that runs the sysprep specialize/oobe pass) to search for an Unattend.xml configuration file on the context iso. If the Unattend.xml file is not found, setup will continue using the cached copy inside the WINDOWS\Setup directory inside the image. This means you can safely configure your images to use this feature without affecting compatibility with context.ps1

#### How to set up the context-helper web server

This note is for Ubuntu 14.04. Package names may differ if using another distro.

1. Install the following packages
  - apache2
  - opennebula-tools
  - ruby-opennebula
  - ruby-nokogiri

2. Place the mkunattend.rb script into the directory /usr/lib/cgi-bin and rename the script to 'makeunattend'. 
  - Set the permissions to 755.
  - Edit the ENV["ONE_XMLRPC"] variable in the makeunattend script to match the XML-RPC interface for your OpenNebula installation.
3. Copy the Unattend-template.xml file to the directory /usr/lib/cgi-bin. Set the permissions to 644.
4. Enable the cgi-bin module in apache with the command:
  - a2enmod cgid
5. Restart apache2

Set up a DNS alias for this VM if required. Ensure that the DNS record is resolvable from your opennebula server.

#### How to set up your user account

1. Copy the value of the LOGIN_TOKEN to a new variable in the USER_CONTEXT section. Call this value 'LTOKEN' (you don't have to use the name LTOKEN, but you will need to change the url in the FILES section of the VM template to match if you change this)

#### How to set up your VM template

1. Create a new VM template using the contents of the vm-template.txt file. 
  - Adjust this template (DISK section) to reference your Windows 2012 R2 image.
  - Change the 'context-helper' in the FILES variable of the CONTEXT section to match your DNS entry or IP address of the context-helper VM

#### Boot your VM

2. Instantiate the template as normal. The VM should contextualize and boot. Examine the VM and ensure that the hostname has been set correctly and that no reboots are pending (you can see this by looking at the system properties, which will tell you if a reboot is pending on a hostname change) 

#### Caveats

- This is more proof-of-concept than anything that is production-ready. Use at your own risk.
- The included Unattend-template.xml is suitable for Windows 2012 R2 Standard. You will likely need a different Unattend.xml file for other versions of Windows. the mkunattend.rb script __should__ work with other versions of the Unattend.xml file, provided the proper placeholder sections are in place. However, it has not been tested with aything other than Windows 2012 R2 Standard.
- This configuration only supports setting a single IPV4 address on the VM. It is possible to support multiple addresses and adapters with improvements to the mkunattend.rb script
- This was tested with OpenNebula version 4.14, on the KVM (qemu) hypervisor. It should work on any recent version of OpenNebula.

#### Troubleshooting

- Most issues will cause a 500 server error on the context-helper webserver. This will normally cause the VM to go into ERROR state. Examine the apache server logs on the web server, and you should be able to determine the underlying cause. (e.g. bad credentials)

#### Notes
The compat-context.ps1 is included to handle a couple of features that aren't included in Unattend.xml, the main one is the ability to run scripts during contextualization.

#### License
Apache-2.0
