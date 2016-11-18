------------------------------------------------------------------------------
--                                                                          --
--                        SPARK LIBRARY COMPONENTS                          --
--                                                                          --
--       S P A R K . C O N S T R A I N E D _ A R R A Y _ L E M M A S        --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--                       Copyright (C) 2016, AdaCore                        --
--                                                                          --
-- SPARK is free software;  you can  redistribute it and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion. SPARK is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

generic
   type Index_Type is range <>;
   type Element_T is private;
   type A is array (Index_Type) of Element_T;
   --  This function has to be transitive like "<" in Ada:
   --  transitivity: forall x y z, x < y -> y < z -> x < z
   --  If this property is not ensured, the lemmas are likely to
   --  introduce inconsistencies.
   with function Less (X, Y : Element_T) return Boolean;

package SPARK.Constrained_Array_Lemmas
with SPARK_Mode,
     Pure,
     Ghost
is

   procedure Lemma_Transitive_Order (Arr : A) with
       Pre =>
         (for all I in Arr'First + 1 .. Arr'Last =>
            (Less (Arr (I - 1), (Arr (I))))),
       Post => (for all I in Arr'Range =>
                  (for all J in Arr'Range =>
                     (if I < J then Less (Arr (I), Arr (J)))));

end SPARK.Constrained_Array_Lemmas;
