------------------------------------------------------------------------------
--                            IPSTACK COMPONENTS                            --
--             Copyright (C) 2010, Free Software Foundation, Inc.           --
------------------------------------------------------------------------------

--  IP layer

with AIP.IPaddrs, AIP.NIF, AIP.Buffers;

--# inherit AIP.IPaddrs, AIP.NIF, AIP.Buffers;

package AIP.IP is

   procedure Set_Default_Router (IPA : IPaddrs.IPaddr);
   --  Set the default route to the given value

   --  IP_PCB is the common part of the PCB for all IP-based protocols

   type IP_PCB is record
      Local_IP  : IPaddrs.IPaddr;
      Remote_IP : IPaddrs.IPaddr;

      SOO : AIP.U16_T;
      --  Socket options
      --  Should use boolean components instead???

      TOS : AIP.U8_T;
      --  Type Of Service

      TTL : AIP.U8_T;
      --  Time To Live
   end record;

   procedure IP_Route
     (Dst_IP   : IPaddrs.IPaddr;
      Next_Hop : out IPaddrs.IPaddr;
      Netif    : out AIP.EID);
   --  Find next hop IP address and outbound interface for Dst_IP

   procedure IP_Input (Netif : NIF.Netif_Id; Buf : Buffers.Buffer_Id);
   pragma Export (C, IP_Input, "AIP_ip_input");

   procedure IP_Output_If
     (Buf    : Buffers.Buffer_Id;
      Src_IP : IPaddrs.IPaddr;
      Dst_IP : IPaddrs.IPaddr;
      NH_IP  : IPaddrs.IPaddr;
      TTL    : AIP.U8_T;
      TOS    : AIP.U8_T;
      Proto  : AIP.U8_T;
      Netif  : NIF.Netif_Id;
      Err    : out AIP.Err_T);
   --  Output IP datagram
   --  ... and deallocate Buf???

   IP_HLEN : constant := 20;
   --  What if there are options???

private

   procedure IP_Forward (Buf : Buffers.Buffer_Id; Netif : NIF.Netif_Id);
   --  Decrement TTL and forward packet to next hop

end AIP.IP;
