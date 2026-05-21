$modules = "Microsoft.Graph", "Microsoft.Graph.Beta"

foreach ($item in $modules) {
   $latest = (Find-Module -name $item).version 
   $current = (Get-InstalledModule -name $item).version

   Write-Host ("Latest version of $item is $latest, currently installed is $current")
}