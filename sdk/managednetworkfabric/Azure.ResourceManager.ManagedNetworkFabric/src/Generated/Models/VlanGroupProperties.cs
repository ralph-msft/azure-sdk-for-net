// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

// <auto-generated/>

#nullable disable

using System.Collections.Generic;
using Azure.Core;

namespace Azure.ResourceManager.ManagedNetworkFabric.Models
{
    /// <summary> Vlan group properties. </summary>
    public partial class VlanGroupProperties
    {
        /// <summary> Initializes a new instance of VlanGroupProperties. </summary>
        public VlanGroupProperties()
        {
            Vlans = new ChangeTrackingList<string>();
        }

        /// <summary> Initializes a new instance of VlanGroupProperties. </summary>
        /// <param name="name"> Vlan group name. </param>
        /// <param name="vlans"> List of vlans. </param>
        internal VlanGroupProperties(string name, IList<string> vlans)
        {
            Name = name;
            Vlans = vlans;
        }

        /// <summary> Vlan group name. </summary>
        public string Name { get; set; }
        /// <summary> List of vlans. </summary>
        public IList<string> Vlans { get; }
    }
}
