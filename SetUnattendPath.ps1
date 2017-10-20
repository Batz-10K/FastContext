# Prime the sysprep specialize process to grab unattend.xml off the context cd. This context CD *must* be drive D:
# Run this after Sysprep-ing your image, but before you shut down to clone the image. 
$unattendpath = "HKLM:\System\Setup"
New-ItemProperty -Path $unattendpath -Name "UnattendFile" -Value "D:\Unattend.xml" -PropertyType STRING
