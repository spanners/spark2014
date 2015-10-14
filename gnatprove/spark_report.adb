------------------------------------------------------------------------------
--                                                                          --
--                            GNATPROVE COMPONENTS                          --
--                                                                          --
--                           S P A R K _ R E P O R T                        --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                       Copyright (C) 2010-2015, AdaCore                   --
--                                                                          --
-- gnatprove is  free  software;  you can redistribute it and/or  modify it --
-- under terms of the  GNU General Public License as published  by the Free --
-- Software  Foundation;  either version 3,  or (at your option)  any later --
-- version.  gnatprove is distributed  in the hope that  it will be useful, --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of  MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General Public License  distributed with  gnatprove;  see file COPYING3. --
-- If not,  go to  http://www.gnu.org/licenses  for a complete  copy of the --
-- license.                                                                 --
--                                                                          --
-- gnatprove is maintained by AdaCore (http://www.adacore.com)              --
--                                                                          --
------------------------------------------------------------------------------

--  This program (SPARK_Report) is run at the very end of SPARK analysis (see
--  also the comment in gnatprove.adb). The different bits of analysis have
--  stored the results of the analysis in one result file per unit, This
--  program reads all those files in and prints a summary in a file called
--  "gnatprove.out".
--
--  For each unit, the tool expects a file "<unit>.spark" be be present. This
--  file is in JSON format. The following comments describe the format of this
--  file.
--
--  --------------
--  -- Entities --
--  --------------
--
--  At various places, we refer to entities. These are Ada entities,
--  subprograms or packages. Entities are defined by their name and their
--  source location (file and line). In JSON this translates to the following
--  dictionary for entities:
--    { name  : string,
--      file  : string,
--      line  : int }

--  ---------------------------
--  -- The SPARK result file --
--  ---------------------------
--
--  The file is of this form:
--    { "spark" : list spark_result,
--      "flow"  : list flow_result,
--      "proof" : list proof_result }
--
--  Each entry is mapped to a list of entries whose format is described below.
--
--  ------------------------
--  -- SPARK status entry --
--  ------------------------
--
--  This entry is simply an entity, with an extra field for spark status, so
--  that the entire dict looks like this:
--    spark_result = { name  : string,
--                     file  : string,
--                     line  : int,
--                     spark : string }
--  Field "spark" takes value in "spec", "all" or "no" to denote
--  respectively that only the spec is in SPARK, both spec/body are in SPARK
--  (or spec is in SPARK for a package without body), or the spec is not in
--  SPARK.
--
--  ------------------
--  --  Proof entry --
--  ------------------
--
--  Entries for proof are of the following form: proof_result =
--    { file       : string,
--      line       : int,
--      col        : int,
--      suppressed : string,
--      rule       : string,
--      severity   : string,
--      tracefile  : string,
--      msg_id     : int,
--      how_proved : string,
--      entity     : entity }
--  - (file, line, col) describe the source location of the message.
--  - "rule" describes the kind of VC, the possible values are described
--    in the file vc_kinds.ads.
--  - "severity" describes the kind status of the message, possible values used
--    by gnatwhy3 are "info", "low", "medium", "high" and "error"
--  - "tracefile" contains the name of a trace file, if any
--  - "entity" contains the entity dictionary for the entity that this VC
--    belongs to
--  - "msg_id" - if present indicates that this entry corresponds to a message
--    issued on the commandline, with the exact same msg_id in brackets:
--    "[#12]"
--  - "suppressed" - if present, the message is in fact suppressed by a pragma
--    Annotate, and this field contains the justification message.
--  - "how_proved" - if present, indicates how the VC has been proved (i.e.
--    which prover). A special value is the string "interval" which designates
--    the special interval analysis done in the frontend, and wich corresponds
--    to the Interval column in the summary table.
--
--  -----------------
--  --  Flow Entry --
--  -----------------
--
--  Flow entries are of the same form as for proof. Differences are in the
--  possible values for "rule", which can only be tho ones for flow messages.
--  Also "how_proved" field is never set.

with Ada.Containers;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Assumptions;                         use Assumptions;
with Assumptions.Search;                  use Assumptions.Search;
with Assumption_Types;                    use Assumption_Types;
with Call;                                use Call;
with Configuration;                       use Configuration;
with GNAT.Directory_Operations.Iteration;
with GNAT.OS_Lib;                         use GNAT.OS_Lib;
with GNATCOLL.JSON;                       use GNATCOLL.JSON;
with GNATCOLL.Utils;                      use GNATCOLL.Utils;
with Print_Table;                         use Print_Table;
with Report_Database;                     use Report_Database;
with String_Utils;                        use String_Utils;
with VC_Kinds;                            use VC_Kinds;

procedure SPARK_Report is

   No_Analysis_Done : Boolean := True;

   Assumptions      : Boolean := False;

   function Parse_Command_Line return String;
   --  parse the command line and set the variables Assumptions and Limit_Subp.
   --  return the name of the file which contains the object dirs to be
   --  scanned.

   procedure Handle_SPARK_File (Fn : String);
   --  Parse and extract all information from a single SPARK file.
   --  No_Analysis_Done is set to true if no subprogram or package was
   --  analyzed in this unit.

   procedure Handle_Flow_Items (V : JSON_Array; Unit : Unit_Type);
   --  Parse and extract all information from a flow result array

   procedure Handle_Proof_Items (V : JSON_Array; Unit : Unit_Type);
   --  Parse and extract all information from a proof result array

   procedure Handle_Assume_Items (V : JSON_Array; Unit : Unit_Type);
   --  Parse and extract all information from a proof result array

   procedure Handle_Source_Dir (Dir : String);
   --  Parse all result files of this directory.

   procedure Print_Analysis_Report (Handle : Ada.Text_IO.File_Type);
   --  print the proof report in the given file

   procedure Compute_Assumptions;
   --  compute remaining assumptions for all subprograms and store them in
   --  database

   function To_String (Sloc : My_Sloc) return String;
   --  pretty printing of slocs including instantiation chains

   procedure Dump_Summary_Table (Handle : Ada.Text_IO.File_Type);
   --  Print the summary table to a file
   --  @param Handle the file handle to print the summary table to

   procedure Increment (X : in out Integer);
   --  @param X increment this parameter by 1

   function VC_Kind_To_Summary (S : VC_Kind) return Summary_Entries;
   --  @param S a VC kind like VC_DIVISION_CHECK etc
   --  @return the corresponding summary entry which this VC corresponds to

   function Flow_Kind_To_Summary (S : Flow_Tag_Kind) return Possible_Entries;
   --  @param S a Flow kind like VC_DIVISION_CHECK etc
   --  @return the corresponding summary entry which this VC corresponds to

   function To_String (S : Summary_Entries) return String;
   --  compute the string which will appear in the leftmost column of the
   --  summary table for each check kind
   --  @param S the table line
   --  @return a string to be presented to the user

   procedure Process_Stats (C : Summary_Entries; Stats : JSON_Value);
   --  process the stats record for the VC and update the proof information
   --  @param C the category of the VC
   --  @param Stats the stats record

   -------------------------
   -- Compute_Assumptions --
   -------------------------

   procedure Compute_Assumptions is
   begin

      --  ??? This is slow, use a better algorithm in Assumptions.Search

      for C of Get_All_Claims loop
         declare
            S : constant Token_Sets.Set := Claim_Depends_On (C);
         begin
            Add_Claim_With_Assumptions (C, S);
         end;
      end loop;
   end Compute_Assumptions;

   ------------------------
   -- Dump_Summary_Table --
   ------------------------

   procedure Dump_Summary_Table (Handle : Ada.Text_IO.File_Type) is

      T               : Table := Create_Table (Lines => 10, Cols => 7);

      procedure Print_Table_Header;
      --  print the header of the table

      procedure Print_Table_Line (Line : Summary_Entries);
      --  print a line of the table other than the header and the total line
      --  @param Line the entry of the summary to be printed

      procedure Print_Table_Total;
      --  print the "Total" line of the table

      procedure Put_Provers_Cell (Stats : in out Prover_Stat);
      --  print the "provers" cell of a category, with the total count of
      --  checks and the percentage of each prover
      --  @param Stats the stats for the prover

      procedure Put_Total_Cell (Part, Total : Natural);
      --  print a number cell, and if not zero, print the percentage this
      --  represents in some total, in the way "32 (14%)"
      --  @param Part the number to be shown in this cell
      --  @param Total the total (ie. 100%)

      procedure Compute_Total_Summary_Line;
      --  compute the numbers for the "Total" line of the summary table

      function Integer_Percent (Part, Total : Integer) return Integer;
      --  compute the percentage of Part in Total, using Integers
      --  @param Part the part
      --  @param Total the total count
      --  @return an integer close to the percentage that Part represents of
      --  Total

      --------------------------------
      -- Compute_Total_Summary_Line --
      --------------------------------

      procedure Compute_Total_Summary_Line is
         Tot : Summary_Line renames Summary (Total);
      begin
         for Entr in Summary_Entries range Data_Dep .. LSP loop
            Tot.Flow := Tot.Flow + Summary (Entr).Flow;
            Tot.Interval :=
              Tot.Interval + Summary (Entr).Interval;
            Tot.Provers.Total :=
              Tot.Provers.Total + Summary (Entr).Provers.Total;
            Tot.Justified := Tot.Justified + Summary (Entr).Justified;
            Tot.Unproved := Tot.Unproved + Summary (Entr).Unproved;
         end loop;
      end Compute_Total_Summary_Line;

      ---------------------
      -- Integer_Percent --
      ---------------------

      function Integer_Percent (Part, Total : Integer) return Integer is
      begin
         return Integer ((Float (100 * Part)) / Float (Total));
      end Integer_Percent;

      ------------------------
      -- Print_Table_Header --
      ------------------------

      procedure Print_Table_Header is
      begin

         --  the very first cell is the upper left corner of the table, which
         --  is empty

         Put_Cell (T, "SPARK Analysis results", Align => Left_Align);
         Put_Cell (T, "Total");
         Put_Cell (T, "Flow");
         Put_Cell (T, "Interval");
         Put_Cell (T, "Provers");
         Put_Cell (T, "Justified");
         Put_Cell (T, "Unproved");
         New_Line (T);
      end Print_Table_Header;

      ----------------------
      -- Print_Table_Line --
      ----------------------

      procedure Print_Table_Line (Line : Summary_Entries) is
         Elt : Summary_Line := Summary (Line);
         Total : constant Natural :=
           Elt.Flow + Elt.Interval + Elt.Provers.Total +
             Elt.Justified + Elt.Unproved;
      begin
         Put_Cell (T, To_String (Line), Align => Left_Align);
         Put_Cell (T, Total);
         Put_Cell (T, Elt.Flow);
         Put_Cell (T, Elt.Interval);
         Put_Provers_Cell (Elt.Provers);
         Put_Cell (T, Elt.Justified);
         Put_Cell (T, Elt.Unproved);
         New_Line (T);
      end Print_Table_Line;

      -----------------------
      -- Print_Table_Total --
      -----------------------

      procedure Print_Table_Total
      is
         Elt : constant Summary_Line := Summary (Total);
         Tot : constant Natural :=
           Elt.Flow + Elt.Interval + Elt.Provers.Total +
             Elt.Justified + Elt.Unproved;
      begin
         Put_Cell (T, To_String (Total), Align => Left_Align);
         Put_Cell (T, Tot);
         Put_Total_Cell (Elt.Flow, Tot);
         Put_Total_Cell (Elt.Interval, Tot);
         Put_Total_Cell (Elt.Provers.Total, Tot);
         Put_Total_Cell (Elt.Justified, Tot);
         Put_Total_Cell (Elt.Unproved, Tot);
         New_Line (T);
      end Print_Table_Total;

      ----------------------
      -- Put_Provers_Cell --
      ----------------------

      procedure Put_Provers_Cell (Stats : in out Prover_Stat) is
         use Ada.Strings.Unbounded;
         use String_Maps;
         use Ada.Containers;
         Check_Total : constant Natural := Stats.Total;
         VC_Total    : Natural := 0;
         Buf         : Unbounded_String;
         First       : Boolean := True;
      begin
         if Check_Total = 0 or else Stats.Provers.Length = 0 then
            Put_Cell (T, Check_Total);
            return;
         end if;
         Append (Buf, Natural'Image (Check_Total));
         for Elt of Stats.Provers loop
            VC_Total := VC_Total + Elt;
         end loop;
         for Elt of Stats.Provers loop
            Elt := Integer_Percent (Elt, VC_Total);
         end loop;
         Append (Buf, " (");
         if Stats.Provers.Length = 1 then
            Append (Buf, Key (Stats.Provers.First));
         else
            for C in Stats.Provers.Iterate loop
               if not First then
                  Append (Buf, ", ");
               end if;
               First := False;
               Append (Buf, Key (C));
               Append (Buf, " " & Natural'Image (Element (C)) & "%");
            end loop;
         end if;
         Append (Buf, ')');
         Put_Cell (T, To_String (Buf));
      end Put_Provers_Cell;

      --------------------
      -- Put_Total_Cell --
      --------------------

      procedure Put_Total_Cell (Part, Total : Natural) is
      begin
         if Part = 0 then
            Put_Cell (T, 0);
         else
            declare
               Pcnt_Img : constant String :=
                 Integer'Image (Integer_Percent (Part, Total));
               No_Space : constant String :=
                 Pcnt_Img (Pcnt_Img'First + 1 .. Pcnt_Img'Last);
            begin
               Put_Cell (T, Integer'Image (Part) & " (" & No_Space & "%)");
            end;
         end if;
      end Put_Total_Cell;

   begin
      Compute_Total_Summary_Line;
      Ada.Text_IO.Put_Line (Handle, "Summary of SPARK analysis");
      Ada.Text_IO.Put_Line (Handle, "=========================");
      Ada.Text_IO.New_Line (Handle);
      Print_Table_Header;
      for Line in Summary_Entries loop
         if Line = Total then
            Print_Table_Total;
         else
            Print_Table_Line (Line);
         end if;
      end loop;
      Dump_Table (Handle, T);
   end Dump_Summary_Table;

   function Flow_Kind_To_Summary (S : Flow_Tag_Kind) return Possible_Entries is
   begin
      case S is
         when Empty_Tag =>
            return No_Entry;

         when Aliasing =>
            return Non_Aliasing;

         when Global_Missing
            | Global_Wrong
            | Export_Depends_On_Proof_In
            | Hidden_Unexposed_State
            | Illegal_Update
            | Non_Volatile_Function_With_Volatile_Effects
            | Volatile_Function_Without_Volatile_Effects
            | Side_Effects =>

            return Data_Dep;

         when  Impossible_To_Initialize_State
            | Initializes_Wrong
            | Uninitialized
            | Default_Initialization_Missmatch =>

            return Init;

         when Depends_Null
            | Depends_Missing
            | Depends_Missing_Clause
            | Depends_Wrong =>

            return Flow_Dep;

         when Dead_Code
            | Ineffective
            | Inout_Only_Read
            | Missing_Return
            | Not_Constant_After_Elaboration
            | Pragma_Elaborate_All_Needed
            | Stable
            | Unused
            | Unused_Initial_Value =>
            return No_Entry;
      end case;
   end Flow_Kind_To_Summary;

   -------------------------
   -- Handle_Assume_Items --
   -------------------------

   procedure Handle_Assume_Items (V : JSON_Array; Unit : Unit_Type) is
      pragma Unreferenced (Unit);
      RL : constant Rule_Lists.List := From_JSON (V);
   begin
      Import (RL);
   end Handle_Assume_Items;

   -----------------------
   -- Handle_Flow_Items --
   -----------------------

   procedure Handle_Flow_Items (V : JSON_Array; Unit : Unit_Type) is
   begin
      for Index in 1 .. Length (V) loop
         declare
            Result : constant JSON_Value := Get (V, Index);
            Severe : constant String     := Get (Get (Result, "severity"));
            Subp   : constant Subp_Type  := From_JSON (Get (Result, "entity"));
            Kind   : constant Flow_Tag_Kind :=
              Flow_Tag_Kind'Value (Get (Get (Result, "rule")));
            Category : constant Possible_Entries :=
              Flow_Kind_To_Summary (Kind);
         begin
            if Has_Field (Result, "suppressed") then
               Add_Suppressed_Warning
                 (Unit   => Unit,
                  Subp   => Subp,
                  Reason => Get (Get (Result, "suppressed")),
                  File   => Get (Get (Result, "file")),
                  Line   => Get (Get (Result, "line")),
                  Column => Get (Get (Result, "col")));
               if Category /= No_Entry then
                  Increment (Summary (Category).Justified);
               end if;
            elsif Severe = "info" then
               --  Ignore flow info messages for now.
               if Category /= No_Entry then
                  Increment (Summary (Category).Flow);
               end if;
            else
               Add_Flow_Result
                 (Unit  => Unit,
                  Subp  => Subp,
                  Error => Severe = "error");
               if Category /= No_Entry then
                  Increment (Summary (Category).Unproved);
               end if;
            end if;
         end;
      end loop;
   end Handle_Flow_Items;

   ------------------------
   -- Handle_Proof_Items --
   ------------------------

   procedure Handle_Proof_Items (V : JSON_Array; Unit : Unit_Type) is
   begin
      for Index in 1 .. Length (V) loop
         declare
            Result   : constant JSON_Value := Get (V, Index);
            Severe   : constant String     := Get (Get (Result, "severity"));
            Kind     : constant VC_Kind    :=
              VC_Kind'Value (Get (Get (Result, "rule")));
            Subp     : constant Subp_Type :=
              From_JSON (Get (Result, "entity"));
            Category : constant Summary_Entries :=
              VC_Kind_To_Summary (Kind);
            Proved   : constant Boolean := Severe = "info";
         begin
            if Has_Field (Result, "suppressed") then
               Increment (Summary (Category).Justified);
               Add_Suppressed_Warning
                 (Unit   => Unit,
                  Subp   => Subp,
                  Reason => Get (Get (Result, "suppressed")),
                  File   => Get (Get (Result, "file")),
                  Line   => Get (Get (Result, "line")),
                  Column => Get (Get (Result, "col")));
            else
               Add_Proof_Result
                 (Unit   => Unit,
                  Subp   => Subp,
                  Proved => Proved);
               if Proved then
                  if Has_Field (Result, "how_proved")
                    and then Get (Get (Result, "how_proved")) = "interval"
                  then
                     Increment (Summary (Category).Interval);
                  else
                     if Has_Field (Result, "stats") then
                        Process_Stats (Category, Get (Result, "stats"));
                     end if;
                     Increment (Summary (Category).Provers.Total);
                  end if;
               else
                  Increment (Summary (Category).Unproved);
               end if;
            end if;
         end;
      end loop;
   end Handle_Proof_Items;

   -----------------------
   -- Handle_Source_Dir --
   -----------------------

   procedure Handle_Source_Dir (Dir : String) is

      procedure Local_Handle_SPARK_File
        (Item    : String;
         Index   : Positive;
         Quit    : in out Boolean);
      --  Wrapper for Handle_SPARK_File

      -----------------------------
      -- Local_Handle_SPARK_File --
      -----------------------------

      procedure Local_Handle_SPARK_File
        (Item    : String;
         Index   : Positive;
         Quit    : in out Boolean)
      is
      begin
         pragma Unreferenced (Index);
         pragma Unreferenced (Quit);
         Handle_SPARK_File (Item);
      end Local_Handle_SPARK_File;

      procedure Iterate_SPARK is new
         GNAT.Directory_Operations.Iteration.Wildcard_Iterator
          (Action => Local_Handle_SPARK_File);

      Save_Dir : constant String := Ada.Directories.Current_Directory;

   --  Start of processing for Handle_Source_Dir

   begin
      Ada.Directories.Set_Directory (Dir);
      Iterate_SPARK (Path => "*." & VC_Kinds.SPARK_Suffix);
      Ada.Directories.Set_Directory (Save_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Save_Dir);
         raise;
   end Handle_Source_Dir;

   -----------------------
   -- Handle_SPARK_File --
   -----------------------

   procedure Handle_SPARK_File (Fn : String) is
         Dict      : constant JSON_Value :=
           Read (Read_File_Into_String (Fn), Fn);
         Basename  : constant String := Ada.Directories.Base_Name (Fn);
         Unit      : constant Unit_Type := Mk_Unit (Basename);
         Has_Flow  : constant Boolean := Has_Field (Dict, "flow");
         Has_Proof : constant Boolean := Has_Field (Dict, "proof");

         --  Status of analysis performed on all subprograms and packages of a
      --  unit depend on presence of the "flow" and "proof" files present in
      --  the .spark result file.

      --  This status is only relevant for subprograms and packages which are
      --  in SPARK. Also, we do not currently take into account the fact that
      --  possibly a single subprogram/line in the unit was analyzed.

      Analysis : constant Analysis_Status :=
        (if Has_Flow and Has_Proof then Flow_And_Proof
         elsif Has_Flow then Flow_Analysis
         elsif Has_Proof then Proof_Only
         else No_Analysis);

      Entries : constant JSON_Array := Get (Get (Dict, "spark"));
   begin
      for Index in 1 .. Length (Entries) loop
         declare
            Result   : constant JSON_Value := Get (Entries, Index);
            In_SPARK : constant Boolean :=
              Get (Get (Result, "spark")) = "all";
         begin
            Add_SPARK_Status
              (Unit         => Unit,
               Subp         => From_JSON (Result),
               SPARK_Status => In_SPARK,
               Analysis     => Analysis);

            --  If at least one subprogram or package was analyzed (either
            --  flow analysis or proof), then record that the analysis was
            --  effective.

            if In_SPARK and Analysis /= No_Analysis then
               No_Analysis_Done := False;
            end if;
         end;
      end loop;
      if Has_Flow then
         Handle_Flow_Items (Get (Get (Dict, "flow")), Unit);
      end if;
      if Has_Proof then
         Handle_Proof_Items (Get (Get (Dict, "proof")), Unit);
      end if;
      if Assumptions and then Has_Field (Dict, "assumptions") then
         Handle_Assume_Items (Get (Get (Dict, "assumptions")), Unit);
      end if;
   end Handle_SPARK_File;

   ---------------
   -- Increment --
   ---------------

   procedure Increment (X : in out Integer) is
   begin
      X := X + 1;
   end Increment;

   ------------------------
   -- Parse_Command_Line --
   ------------------------

   function Parse_Command_Line return String is

      use Ada.Command_Line;

      Source_Dirs : access String := null;
   begin
      for Index in 1 .. Argument_Count loop
         declare
            S : constant String := Argument (Index);
         begin
            if S = "--assumptions" then
               Assumptions := True;
            elsif GNATCOLL.Utils.Starts_With (S, "--limit-subp=") then

               --  ??? FIXME --limit-subp currently ignored

               null;
            elsif GNATCOLL.Utils.Starts_With (S, "--") then
               Abort_With_Message ("unknown option: " & S);
            elsif Source_Dirs = null then
               Source_Dirs := new String'(S);
            else
               Abort_With_Message ("more than one file given, aborting");
            end if;
         end;
      end loop;
      if Source_Dirs = null then
         Abort_With_Message ("No source directory file given, aborting");
      end if;
      return Source_Dirs.all;
   end Parse_Command_Line;

   ---------------------------
   -- Print_Analysis_Report --
   ---------------------------

   procedure Print_Analysis_Report (Handle : Ada.Text_IO.File_Type) is
      use Ada.Text_IO;

      procedure For_Each_Unit (Unit : Unit_Type);
      --  print proof results for the given unit

      -------------------
      -- For_Each_Unit --
      -------------------

      procedure For_Each_Unit (Unit : Unit_Type) is

         procedure For_Each_Subp (Subp : Subp_Type; Stat : Stat_Rec);

         -------------------
         -- For_Each_Subp --
         -------------------

         procedure For_Each_Subp (Subp : Subp_Type; Stat : Stat_Rec) is
         begin
            Put (Handle,
                 "  " & Subp_Name (Subp) & " at " &
                   To_String (Subp_Sloc (Subp)));

            if Stat.SPARK then
               if Stat.Analysis = No_Analysis then
                  Put_Line (Handle, " not analyzed");
               else
                  if Stat.Analysis in Flow_Analysis | Flow_And_Proof then
                     Put (Handle,
                          " flow analyzed ("
                          & Image (Stat.Flow_Errors, 1) & " errors and "
                          & Image (Stat.Flow_Warnings, 1) & " warnings)");
                  end if;

                  if Stat.Analysis = Flow_And_Proof then
                     Put (Handle, " and");
                  end if;

                  if Stat.Analysis in Proof_Only | Flow_And_Proof then
                     if Stat.VC_Count = Stat.VC_Proved then
                        Put (Handle,
                             " proved ("
                             & Image (Stat.VC_Count, 1) & " checks)");
                     else
                        Put (Handle,
                             " not proved," & Stat.VC_Proved'Img
                             & " checks out of" & Stat.VC_Count'Img
                             & " proved");
                     end if;
                  end if;

                  Put_Line (Handle, "");

                  if not Stat.Suppr_Msgs.Is_Empty then
                     Put_Line (Handle, "   suppressed messages:");
                     for Msg of Stat.Suppr_Msgs loop
                        Put_Line (Handle,
                                  "    " &
                                  Ada.Strings.Unbounded.To_String (Msg.File) &
                                    ":" & Image (Msg.Line, 1) & ":" &
                                    Image (Msg.Column, 1) & ": " &
                                    Ada.Strings.Unbounded.To_String
                                    (Msg.Reason));
                     end loop;
                  end if;

                  if Assumptions then
                     for Rule of Stat.Assumptions loop
                        if Rule.Assumptions.Is_Empty then
                           Ada.Text_IO.Put_Line
                             (Handle,
                              To_String (Rule.Claim) & " fully established");
                        else
                           Ada.Text_IO.Put_Line
                             (Handle, To_String (Rule.Claim) & " depends on");
                           for A of Rule.Assumptions loop
                              Ada.Text_IO.Put_Line
                                (Handle, "  " & To_String (A));
                           end loop;
                        end if;
                     end loop;
                  end if;
               end if;

            else
               Put_Line (Handle, " skipped");
            end if;
         end For_Each_Subp;

      begin
         Put_Line (Handle,
                   "in unit " & Unit_Name (Unit) & ", "
                   & Image (Num_Subps_SPARK (Unit), 1)
                   & " subprograms and packages out of "
                   & Image (Num_Subps (Unit), 1) & " analyzed");
         Iter_Unit_Subps (Unit, For_Each_Subp'Access, Ordered => True);

      end For_Each_Unit;

      N_Un : constant Integer := Num_Units;

   --  Start of processing for Print_Analysis_Report

      Unit_Str : constant String :=
        (if N_Un = 1 then "unit" else "units");
   begin
      if N_Un > 0 then
         Put_Line (Handle, "Analyzed" & N_Un'Img & " " & Unit_Str);
         Iter_Units (For_Each_Unit'Access, Ordered => True);
      end if;
   end Print_Analysis_Report;

   -------------------
   -- Process_Stats --
   -------------------

   procedure Process_Stats (C : Summary_Entries; Stats : JSON_Value) is

      procedure Process_Prover_Stat (Name : UTF8_String; Value : JSON_Value);

      procedure Process_Prover_Stat (Name : UTF8_String; Value : JSON_Value) is
         use String_Maps;
         Cur : constant Cursor := Summary (C).Provers.Provers.Find (Name);
         Count : constant Natural := Get (Value, "count");
      begin
         if Has_Element (Cur) then
            declare
               Tmp : Natural := Element (Cur);
            begin
               Tmp := Tmp + Count;
               Replace_Element (Summary (C).Provers.Provers, Cur, Tmp);
            end;
         else
            Summary (C).Provers.Provers.Insert (Name, Count);
         end if;
      end Process_Prover_Stat;

   begin
      Map_JSON_Object (Stats, Process_Prover_Stat'Access);
   end Process_Stats;

   -----------------------------
   -- String_To_Summary_Entry --
   -----------------------------

   function VC_Kind_To_Summary (S : VC_Kind) return Summary_Entries is
   begin
      case S is
         when VC_Division_Check
            | VC_Index_Check
            | VC_Overflow_Check
            | VC_Range_Check
            | VC_Predicate_Check
            | VC_Length_Check
            | VC_Discriminant_Check
            | VC_Tag_Check
            | VC_Ceiling_Interrupt
            | VC_Task_Termination
            | VC_Raise
         =>
            return Runtime_Checks;

         when VC_Assert
            | VC_Loop_Invariant
            | VC_Loop_Invariant_Init
            | VC_Loop_Invariant_Preserv
            | VC_Loop_Variant
         =>
            return Assertions;

         when VC_Initial_Condition
            | VC_Default_Initial_Condition
            | VC_Precondition
            | VC_Precondition_Main
            | VC_Postcondition
            | VC_Refined_Post
            | VC_Contract_Case
            | VC_Disjoint_Contract_Cases
            | VC_Complete_Contract_Cases
         =>
            return Functional_Contracts;

         when VC_Weaker_Pre
            | VC_Trivial_Weaker_Pre
            | VC_Stronger_Post
            | VC_Weaker_Classwide_Pre
            | VC_Stronger_Classwide_Post
         =>
            return LSP;
      end case;
   end VC_Kind_To_Summary;

   ---------------
   -- To_String --
   ---------------

   function To_String (Sloc : My_Sloc) return String is

      use Ada.Strings.Unbounded;

      First : Boolean := True;
      UB    : Unbounded_String := Null_Unbounded_String;
   begin
      for S of Sloc loop
         if not First then
            Append (UB, ", instantiated at ");
         else
            First := False;
         end if;
         Append (UB, Base_Sloc_File (S));
         Append (UB, ":");
         Append (UB, Image (S.Line, 1));
      end loop;
      return To_String (UB);
   end To_String;

   function To_String (S : Summary_Entries) return String is
   begin
      case S is
         when Data_Dep             => return "Data Dependencies";
         when Flow_Dep             => return "Flow Dependencies";
         when Init                 => return "Initialization";
         when Non_Aliasing         => return "Non-Aliasing";
         when Runtime_Checks       => return "Run-time Checks";
         when Assertions           => return "Assertions";
         when Functional_Contracts => return "Functional Contracts";
         when LSP                  => return "LSP Verification";
         when Total                => return "Total";
      end case;
   end To_String;

   procedure Iterate_Source_Dirs is new For_Line_In_File (Handle_Source_Dir);

   Source_Directories_File : constant String := Parse_Command_Line;

   use Ada.Text_IO;

   Handle : File_Type;

--  Start of processing for SPARK_Report

begin
   Iterate_Source_Dirs (Source_Directories_File);
   if No_Analysis_Done then
      Reset_All_Results;
   end if;

   Create (Handle,
           Out_File,
           Configuration.SPARK_Report_File
             (GNAT.Directory_Operations.Dir_Name (Source_Directories_File)));
   if Assumptions then
      Compute_Assumptions;
   end if;
   if not No_Analysis_Done then
      Dump_Summary_Table (Handle);
      Ada.Text_IO.New_Line (Handle);
      Ada.Text_IO.New_Line (Handle);
   end if;
   Print_Analysis_Report (Handle);
   Close (Handle);
end SPARK_Report;
