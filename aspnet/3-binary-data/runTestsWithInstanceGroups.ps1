Import-Module ..\..\BuildTools.psm1 -DisableNameChecking
Import-Module ..\..\InstanceTools.psm1 -DisableNameChecking

Set-BookStore datastore
Build-Solution
Create-InstanceGroup | Test-InstanceGroupIsReady | Run-InstanceGroupTest
Delete-InstanceGroup