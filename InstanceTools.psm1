# Copyright(c) 2016 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

##############################################################################
# HOW TO USE THE FUNCTIONS IN THIS MODULE
##############################################################################
<#

PS ...> Import-Module .\InstanceTools.psm1
WARNING: The names of some imported commands from the module 'InstanceTools'
include unapproved verbs that might make them less discoverable. To find the
commands with unapproved verbs, run the Import-Module command again with the
Verbose parameter. For a list of approved verbs, type Get-Verb.

#>

##############################################################################
#.SYNOPSIS
# Establish unique names for the Google Cloud Platform resources to be
# created.
#
#.DESCRIPTION
# Generate names for the Google Cloud Platform resources to be created. Append
# an identical timestamp to each name in order to create unique names for
# the resources each time this script is run.
#
#.EXAMPLE
# Create-ResourceNames
##############################################################################
filter Create-ResourceNames {
  $timeStamp = "-$(get-date -f yyyy-MM-dd-hhmm)"
  $script:snapshot = "aspnet-snapshot" + $timeStamp
  $script:VMandDiskToCreateFromSnapshot = "aspnet-instance" + $timeStamp
  $script:instanceGroupVMimage = "instance-group-vm-image" + $timeStamp
  $script:instanceGroupTemplate = "instance-template" + $timeStamp
  $script:healthCheck = "instance-group-health-check" + $timeStamp
  $script:instanceGroup = "aspnet-group" + $timeStamp
  $script:backendService = "aspnet-group-backend-service" + $timeStamp
  $script:urlMap = "aspnet-group-url-map" + $timeStamp
  $script:targetProxy = "aspnet-group-lb-proxy" + $timeStamp
  $script:forwardingRule = "aspnet-group-forwarding-rule" + $timeStamp
}

##############################################################################
#.SYNOPSIS
# Creates an autoscaled Instance Group based on a Snapshot of the Google
# Compute Engine VM instance where this script is invoked.
#
#.DESCRIPTION
# Given a VM instance with a running version of the ASP.NET Bookshelf sample
# app, create all the Google Cloud Platform resources necessary to deploy an
# Instance Group running the same Bookshelf sample app. The deployed Instance
# Group is configured to be accessed via an HTTP(S) Load Balancer. The Instance
# Group scales the number of VM instances in the group up or down depending
# on visitor traffic to the HTTP(S) Load Balancer.
#
#.OUTPUTs
# The IP Address of the Load Balancer Forwarding Rule where the Instance Group
# is running.
#
#.EXAMPLE
# Create-InstanceGroup
##############################################################################
function Create-InstanceGroup {
  <# Create preliminary resources necessary to create an Instance Group. #>

  # Get Compute Engine instance name from the machine where this script was invoked.
  Write-Host "Getting VM instance name and zone."
  $VMtoSnapshot = Get-InstanceName

  # Get the Zone for the VM instance that invoked this script.
  $zone = Get-ZoneName("$VMtoSnapshot")

  # Create names for Google Cloud Platform resources.
  Create-ResourceNames

  # Create Snapshot.
  Write-Host "Creating Snapshot."
  gcloud compute disks snapshot $VMtoSnapshot --zone $zone `
  --snapshot-names $snapshot

  # Create a Persistent Disk from the snapshot.
  Write-Host "Creating Persistent Disk from the Snapshot."
  gcloud compute disks create $VMandDiskToCreateFromSnapshot --size "100" `
  --zone $zone --source-snapshot $snapshot --type "pd-standard"

  # Generate list of access scopes to be used for Instance creation.
  $scopes = "https://www.googleapis.com/auth/datastore,"
  $scopes = $scopes + "https://www.googleapis.com/auth/logging.write,"
  $scopes = $scopes + "https://www.googleapis.com/auth/monitoring.write,"
  $scopes = $scopes + "https://www.googleapis.com/auth/servicecontrol,"
  $scopes = $scopes + "https://www.googleapis.com/auth/service.management,"
  $scopes = $scopes + "https://www.googleapis.com/auth/devstorage.read_write,"
  $scopes = $scopes + "https://www.googleapis.com/auth/userinfo.email"

  # Create an Instance from the Snapshot.
  Write-Host "Creating VM instance attached to newly created Persistent Disk."
  gcloud compute instances create $VMandDiskToCreateFromSnapshot `
  --zone $zone --machine-type "n1-standard-1" --network "default" --maintenance-policy "MIGRATE" `
  --disk name="$VMandDiskToCreateFromSnapshot,boot=yes" `
  --metadata "windows-startup-script-ps1=GCESysprep" `
  --scopes default="$scopes" --tags "http-server,https-server"

  # Pause for VM instance to run GCEsysprep and shutdown.
  Write-Host "Sleeping 60 seconds for VM instance to run GCEsysprep and shutdown."
  Start-Sleep -s 60

  # Delete VM instance leaving detached Persistent Disk.
  Write-Host "Deleting VM instance leaving Persistent Disk ready for Imaging."
  gcloud compute instances delete $VMandDiskToCreateFromSnapshot `
  --zone $zone --quiet

  # Create Image from detached Persistent Disk.
  Write-Host "Creating Image from detached Persistent Disk"
  gcloud compute images create $instanceGroupVMimage `
  --source-disk $VMandDiskToCreateFromSnapshot `
  --source-disk-zone $zone

  # Create Instance Template using the newly created Image.
  Write-Host "Creating Instance Template using newly created Image."
  gcloud compute instance-templates create $instanceGroupTemplate `
  --machine-type "n1-standard-1" `
  --network "default" --maintenance-policy "MIGRATE" `
  --scopes default="$scopes" `
  --tags "http-server,https-server" --image $instanceGroupVMimage `
  --boot-disk-size "100" --boot-disk-type "pd-standard" `
  --boot-disk-device-name $instanceGroupTemplate

  <# Create an Instance Group using the Instance Group Template. #>

  # Create a Health Check.
  Write-Host "Creating Health Check."
  gcloud compute http-health-checks create $healthCheck --port "80" `
  --request-path "/Books" --check-interval "30" --timeout "10" `
  --unhealthy-threshold "2" --healthy-threshold "2"

  # Create Instance Group.
  Write-Host "Creating Instance Group."
  gcloud compute instance-groups managed create $instanceGroup `
  --zone $zone --base-instance-name $instanceGroup `
  --template $instanceGroupTemplate --size "1"

  # Configure autoscaling for Instance Group.
  Write-Host "Configuring autoscaling for Instance Group."
  gcloud compute instance-groups managed set-autoscaling $instanceGroup `
  --zone $zone --cool-down-period "410" --max-num-replicas "10" `
  --min-num-replicas "1" --target-load-balancing-utilization "0.8"

  <# Create a Load Balancer with the Instance Group as the Backend Service. #>

  # Define HTTP service and map a port name to the relevant port.
  Write-Host "Configuring port mapping for Instance Group Load Balancer."
  gcloud compute instance-groups managed set-named-ports $instanceGroup `
  --named-ports http:80 --zone $zone

  # Create a Backend Service.
  Write-Host "Configuring Backend Service for Instance Group Load Balancer."
  gcloud compute backend-services create $backendService --protocol HTTP `
  --http-health-check $healthCheck

  # Add Instance Group as a backend to the Backend Service.
  Write-Host "Adding Instance Group as a backend to the Backend Service."
  gcloud compute backend-services add-backend $backendService `
  --balancing-mode RATE --max-rate-per-instance 100 --capacity-scaler 1 `
  --instance-group $instanceGroup --zone $zone

  # Create a default URL Map to direct incoming requests to the Backend Service.
  Write-Host "Adding URL Map to direct incoming requests to the Backend Service."
  gcloud compute url-maps create $urlMap --default-service $backendService

  # Create target HTTP Proxy to route requests to the URL Map.
  Write-Host "Adding target HTTP Proxy to route requests to the URL Map."
  gcloud compute target-http-proxies create $targetProxy --url-map $urlMap

  # Create Global Forwarding Rule.
  Write-Host "Creating Global Forwarding Rule as Instance Group IP Address."
  gcloud compute forwarding-rules create $forwardingRule `
  --global --target-http-proxy $targetProxy --port-range 80

  $forwardingRuleResponse = gcloud compute forwarding-rules `
  describe $forwardingRule --format json --global | Out-String | ConvertFrom-Json

  # Output Instance Group's IP address from Load Balancer Forwarding Rule.
  $forwardingRuleResponse.IPAddress
}

##############################################################################
#.SYNOPSIS
# Given an IP Address for a newly created Instance Group's Load Balancer,
# confirm it returns an HTTP Status code of 200. This ensures the Instance Group
# is responding to HTTP requests and thus is ready for testing.
#
#.DESCRIPTION
# Given an IP Address of an Instance Group's Load Balancer make an HTTP
# request to test for the HTTP status code of 200. A configurable maximum
# number of request attempts will be made based on a configurable interval of
# time between requests. Throws an exception if the maximum number of test
# requests is exceeded without receiving a successful HTTP status code of 200.
#
#.PARAMETER InstanceGroupIPaddress
# The IP Address of the Load Balancer Forwarding Rule where HTTP requests can
# be made to confirm if the Instance Group is running.
#
#.OUTPUTs
# The IP Address of the Load Balancer Forwarding Rule where the Instance Group
# is confirmed to be running.
#
#.EXAMPLE
# Test-InstanceGroupIsReady("0.0.0.0")
##############################################################################
function Test-InstanceGroupIsReady (
  [parameter(ValueFromPipeline=$True)] $InstanceGroupIPaddress ) {

  # Set the maximum number of times to try making requests.
  $maxNumberOfTestRequests = 20
  # Set amount of time in seconds to wait between retries.
  $amountOfTimeToWait = 30
  # Set boolean value to indicate if Instance Group is ready.
  $instanceGroupIsReady = $False
  # Create variable to track number of request attempts made.
  $iterationCount = 1
  While ($iterationCount -le $maxNumberOfTestRequests) {
    Write-Host "Making HTTP request to Instance Group Load Balancer."
    Write-Host "Attempt number $iterationCount out of $maxNumberOfTestRequests."
    $requestUri = "http://$InstanceGroupIPaddress"
    try {
      # Invoke-WebRequest to target IPAddress.
      $HttpRequest = Invoke-WebRequest -Method Head $requestUri
      $HttpStatus = $HttpRequest.statuscode
    } catch {
      $HttpStatus = $_.Exception.Response.StatusCode.Value__
    }
    if ($HttpStatus -eq "200") {
      Write-Host "Instance Group HTTP Status is 200."
      $instanceGroupIsReady = $True
      Break
    } else {
      Write-Host "Instance Group HTTP Status is not 200. (Status: $HttpStatus)"
      $iterationCount++
      if ($iterationCount -le $maxNumberOfTestRequests) {
        Write-Host "Retrying in $amountOfTimeToWait seconds..."
      }
      #Wait before trying again.
      Start-Sleep -s $amountOfTimeToWait
    }
  }
  if ($instanceGroupIsReady) {
    # Output the IP address of the Load Balancer for the running Instance Group.
    $InstanceGroupIPaddress
  } else {
     # Instance Group was not found to be ready.
     # Attempt to delete any resources created for Instance Group then throw error.
     Delete-InstanceGroup
     throw "Failed to create Instance Group"
  }
}

##############################################################################
#.SYNOPSIS
# Get name of VM Instance running this powershell script.
#
#.DESCRIPTION
# Make an HTTP request to the Google Cloud Platform Metadata Server and
# parse the VM Instance name from the response.
#
#.OUTPUTs
# The name of the VM Instance running this powershell script
#
#.EXAMPLE
# Get-InstanceName
##############################################################################
function Get-InstanceName {
  Try {
    # Query the metadata server for the name of the VM instance.
    $metadataUri = "http://metadata.google.internal/computeMetadata/v1/instance/hostname"
    $metadataResponse = Invoke-WebRequest -Headers @{"Metadata-Flavor"="Google"} -Method GET -Uri $metadataUri

    # Split the multi-line response into an array.
    $metadataResponseArray = $metadataResponse.RawContent.Split("`n")

    # Select the last line from the array to get the name of the VM instance.
    $stringToParse = $metadataResponseArray[-1]

    # Parse out the name of the VM instance.
    $endPos = $stringToParse.IndexOf(".")

    # Output VM instance name.
    $stringToParse.Substring(0, $endPos)
  }
  Catch {
    Write-Host "Google Compute Engine VM instance name not found."
    Write-Host "InstanceTools.psm1 must be invoked from a Compute Engine VM."
    Write-Host "Exiting test script."
    exit
  }
}

##############################################################################
#.SYNOPSIS
# Get name of the Zone for the VM Instance running this powershell script.
#
#.DESCRIPTION
# Make an gcloud request for the list of Zones. For each Zone check if the
# given VM Instance is running there.
#
#.PARAMETER vmName
# The name of the VM Instance running this powershell script.
#
#.OUTPUTs
# The name of the Zone for the VM Instance running this powershell script.
#
#.EXAMPLE
# Get-ZoneName("aspnet-bookshelf")
##############################################################################
function Get-ZoneName($vmName) {
  $zones = gcloud compute zones list --format json | Out-String | ConvertFrom-Json
  $vmZone = $null
  # Loop through list of zones, check for VM instance in each zone.
  foreach($zone in $zones)
  {
    try {
      $response = gcloud compute instances describe $vmName `
      --zone $zone.name --format json 2>&1
      $response = $response | Out-String | ConvertFrom-Json
      if($response.status -eq "RUNNING") {
        $vmZone = $zone.name
        break
      }
    } catch {
      # No running VM Instances found for given zone and given VM name.
    }
  }
  if($vmZone) {
    # Output VM instance zone.
    $vmZone
  } else {
    Write-Host "InstanceTools.psm1 must be invoked from a running Compute Engine VM."
    Write-Host "Exiting test script."
    exit
  }
}


##############################################################################
#.SYNOPSIS
# Delete Instance Group and all the resources created to generate it.
#
#.DESCRIPTION
# Deletes the Instance Group and all resources created via the
# Create-InstanceGroup command located within this powershell script module.
#
#.EXAMPLE
# Delete-InstanceGroup
##############################################################################
function Delete-InstanceGroup {
  Write-Host "Deleting Google Cloud Platform resources created for testing."
  # Delete Global Forwarding Rule.
  Write-Host "Attempting to delete Global Forwarding Rule."
  gcloud compute forwarding-rules delete $forwardingRule --quiet
  # Delete Target HTTP Proxy.
  Write-Host "Attempting to delete Target HTTP Proxy."
  gcloud compute target-http-proxies delete $targetProxy --quiet
  # Delete URL map.
  Write-Host "Attempting to delete URL map."
  gcloud compute url-maps delete $urlMap --quiet
  # Remove Instance Group as a backend to the Backend Service.
  Write-Host "Attempting to remove Instance Group as a Backend Service."
  gcloud compute backend-services remove-backend $backendService --quiet
  # Delete Backend Service.
  Write-Host "Attempting to delete Backend Service."
  gcloud compute backend-services delete $backendService --quiet
  # Delete Instance Group.
  Write-Host "Attempting to delete Instance Group."
  gcloud compute instance-groups managed delete $instanceGroup --quiet
  # Delete Health Check.
  Write-Host "Attempting to delete Health Check."
  gcloud compute http-health-checks delete $healthCheck --quiet
  # Delete Instance Template.
  Write-Host "Attempting to delete Instance Template."
  gcloud compute instance-templates delete $instanceGroupTemplate --quiet
  # Delete Image.
  Write-Host "Attempting to delete Image."
  gcloud compute images delete $instanceGroupVMimage --quiet
  # Delete Persistent Disk.
  Write-Host "Attempting to delete Persistent Disk."
  gcloud compute disks delete $VMandDiskToCreateFromSnapshot --quiet
  # Delete Snapshot.
  Write-Host "Attempting to delete Snapshot."
  gcloud compute images delete $snapshot --quiet
  Write-Host "Deletion of Google Cloud Platform resources complete."
}

##############################################################################
#.SYNOPSIS
# Run the test javascript file with casper.
#
#.DESCRIPTION
# Throws an exception if the test fails.
#
#.PARAMETER InstanceGroupIPaddress
# The IP Address of the Load Balancer Forwarding Rule where the Instance
# Group is running.
#
#.PARAMETER TestJs
# The name of the test javascript file to be run with casper.
#
#.EXAMPLE
# Run-InstanceGroupTest("0.0.0.0")
##############################################################################
function Run-InstanceGroupTest(
  [parameter(ValueFromPipeline=$True)] $InstanceGroupIPaddress,
  $TestJs = 'test.js') {
      Start-Sleep -Seconds 4  # Wait for web process to start up.
      casperjs $TestJs http://$InstanceGroupIPaddress
      if ($LASTEXITCODE) {
          throw "Casperjs failed with error code $LASTEXITCODE"
      }
}
