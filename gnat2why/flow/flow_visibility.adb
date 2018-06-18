------------------------------------------------------------------------------
--                                                                          --
--                           GNAT2WHY COMPONENTS                            --
--                                                                          --
--                     F L O W _ V I S I B I L I T Y                        --
--                                                                          --
--                                B o d y                                   --
--                                                                          --
--                   Copyright (C) 2018, Altran UK Limited                  --
--                                                                          --
-- gnat2why is  free  software;  you can redistribute  it and/or  modify it --
-- under terms of the  GNU General Public License as published  by the Free --
-- Software  Foundation;  either version 3,  or (at your option)  any later --
-- version.  gnat2why is distributed  in the hope that  it will be  useful, --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of  MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public License  distributed with  gnat2why;  see file COPYING3. --
-- If not,  go to  http://www.gnu.org/licenses  for a complete  copy of the --
-- license.                                                                 --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Containers.Hashed_Maps;
with Ada.Strings.Unbounded;      use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Atree;                      use Atree;
with Common_Containers;          use Common_Containers;
with Einfo;                      use Einfo;
with Flow_Refinement;            use Flow_Refinement;
with Gnat2Why_Args;
with Graphs;
with Lib;                        use Lib;
with Nlists;                     use Nlists;
with Rtsfind;                    use Rtsfind;
with Sem_Ch12;                   use Sem_Ch12;
with Sem_Util;                   use Sem_Util;
with SPARK_Util;                 use SPARK_Util;
with Sinfo;                      use Sinfo;
with Stand;                      use Stand;

package body Flow_Visibility is

   ----------------------------------------------------------------------------
   --  Types
   ----------------------------------------------------------------------------

   type Hierarchy_Info_T is record
      Is_Package        : Boolean;

--    Is_Child          : Boolean;
--    ??? in the design document this is a dedicated property, but it is easier
--    to debug if implemented as a function; let's keep it like this until this
--    code is stabilized; same for other occurrences below.
      Is_Private        : Boolean;
      Is_Nested         : Boolean;

      Is_Instance       : Boolean;
      Is_Instance_Child : Boolean;

      Parent            : Entity_Id;
      Instance_Parent   : Entity_Id;
      Template          : Entity_Id;
      Container         : Flow_Scope;
   end record;

   package Hierarchy_Info_Maps is new
     Ada.Containers.Hashed_Maps (Key_Type        => Entity_Id,
                                 Element_Type    => Hierarchy_Info_T,
                                 Hash            => Node_Hash,
                                 Equivalent_Keys => "=",
                                 "="             => "=");

   type Edge_Kind is (Rule_Own,
                      Rule_Instance,
                      Rule_Up_Spec,
                      Rule_Down_Spec,
                      Rule_Up_Priv,
                      Rule_Up_Body);

   function Hash (S : Flow_Scope) return Ada.Containers.Hash_Type;

   package Scope_Graphs is new
     Graphs (Vertex_Key   => Flow_Scope,
             Edge_Colours => Edge_Kind,
             Null_Key     => Null_Flow_Scope,
             Key_Hash     => Hash,
             Test_Key     => "=");

   ----------------------------------------------------------------------------
   --  Local variables
   ----------------------------------------------------------------------------

   function Standard_Scope return Flow_Scope is
     (Ent => Standard_Standard, Part => Visible_Part);
   --  ??? this should be a constant, but at the time of elaboration the
   --  Standard_Standard is not yet defined.

   Hierarchy_Info : Hierarchy_Info_Maps.Map;
   Scope_Graph    : Scope_Graphs.Graph := Scope_Graphs.Create;

   Raw_Scope_Graph : Scope_Graphs.Graph;

   ----------------------------------------------------------------------------
   --  Subprogram declarations
   ----------------------------------------------------------------------------

   procedure Close_Visibility_Graph;
   --  Apply transitive closure to the visibility graph; optionally, print and
   --  keep the original for debugging.

   function Sanitize (S : Flow_Scope) return Flow_Scope is
     (if Present (S) then S else Standard_Scope);
   --  Convert between Null_Flow_Scope (which is used in the Flow_Refinement
   --  package) to Standard_Scope (which is used here).

   function Make_Info (N : Node_Id) return Hierarchy_Info_T;

   function Is_Child (Info : Hierarchy_Info_T) return Boolean;

   procedure Print (G : Scope_Graphs.Graph);
   --  Pretty-print visibility graph

   procedure Print_Path (From, To : Flow_Scope);
   pragma Unreferenced (Print_Path);
   --  To be used from the debugger

   generic
      with procedure Process (N : Node_Id);
   procedure Traverse_Compilation_Unit (Unit_Node : Node_Id);
   --  Call Process on all declarations within compilation unit CU. Unlike the
   --  standard frontend traversal, this one traverses into stubs; unlike the
   --  generated globals traversal, this one traverses into generic units.

   ----------------------------------------------------------------------------
   --  Subprogram bodies
   ----------------------------------------------------------------------------

   ----------------------------
   -- Close_Visibility_Graph --
   ----------------------------

   procedure Close_Visibility_Graph is
   begin
      --  Print graph before adding transitive edges
      if Gnat2Why_Args.Flow_Advanced_Debug then

         --  Only print the graph in phase 1
         if Gnat2Why_Args.Global_Gen_Mode then
            Print (Scope_Graph);
         end if;

         --  Retain the original graph for the Print_Path routine

         Raw_Scope_Graph := Scope_Graph;
      end if;

      Scope_Graph.Close;
   end Close_Visibility_Graph;

   -------------------------
   -- Connect_Flow_Scopes --
   -------------------------

   procedure Connect_Flow_Scopes is

      procedure Connect (E : Entity_Id; Info : Hierarchy_Info_T);

      -------------
      -- Connect --
      -------------

      procedure Connect (E : Entity_Id; Info : Hierarchy_Info_T) is

         Spec_V : constant Scope_Graphs.Vertex_Id :=
           Scope_Graph.Get_Vertex ((Ent => E, Part => Visible_Part));

         Priv_V : constant Scope_Graphs.Vertex_Id :=
           (if Info.Is_Package
            then Scope_Graph.Get_Vertex ((Ent => E, Part => Private_Part))
            else Scope_Graphs.Null_Vertex);

         Body_V : constant Scope_Graphs.Vertex_Id :=
           Scope_Graph.Get_Vertex ((Ent => E, Part => Body_Part));
         --  Vertices for the visible (aka. "spec"), private and body parts

         Rule : Edge_Kind;
         --  Rule that causes an edge to be added; maintaining it as a global
         --  variable is not elegant, but results in a cleaner code.

         use type Scope_Graphs.Vertex_Id;

         procedure Connect (Source, Target : Scope_Graphs.Vertex_Id)
         with Pre => Source /= Scope_Graphs.Null_Vertex
                       and
                     Target /= Scope_Graphs.Null_Vertex
                       and
                     Source /= Target;
         --  Add edge from Source to Target

         -------------
         -- Connect --
         -------------

         procedure Connect (Source, Target : Scope_Graphs.Vertex_Id) is
         begin
            Scope_Graph.Add_Edge (Source, Target, Rule);
         end Connect;

      --  Start of processing for Connect

      begin
         ----------------------------------------------------------------------
         --  Create edges
         ----------------------------------------------------------------------

         Rule := Rule_Own;

         --  This rule is the "my own scope" rule, and is the most obvious form
         --  of visibility.

         if Info.Is_Package then
            Connect (Body_V, Priv_V);
            Connect (Priv_V, Spec_V);
         else
            Connect (Body_V, Spec_V);
         end if;

         ----------------------------------------------------------------------

         Rule := Rule_Instance;

         --  This is the "generic" rule. It deals with the special upwards
         --  visibility of generic instances. Instead of following the
         --  normal rules for this we link all our parts to the template's
         --  corresponding parts, since the template's position in the graph
         --  determines our visibility, not the location of instantiation.

         if Info.Is_Instance then
            if Info.Is_Instance_Child then
               Connect
                 (Spec_V,
                  Scope_Graph.Get_Vertex ((Ent  => Info.Instance_Parent,
                                           Part => Visible_Part)));

               if Info.Is_Package then
                  Connect
                    (Priv_V,
                     Scope_Graph.Get_Vertex ((Ent  => Info.Instance_Parent,
                                              Part => Private_Part)));
               end if;

               Connect
                 (Body_V,
                  Scope_Graph.Get_Vertex ((Ent  => Info.Instance_Parent,
                                           Part => Body_Part)));
            else
               Connect
                 (Spec_V,
                  Scope_Graph.Get_Vertex ((Ent  => Info.Template,
                                           Part => Visible_Part)));

               if Info.Is_Package then
                  Connect
                    (Priv_V,
                     Scope_Graph.Get_Vertex ((Ent  => Info.Template,
                                              Part => Private_Part)));
               end if;

               Connect
                 (Body_V,
                  Scope_Graph.Get_Vertex ((Ent  => Info.Template,
                                           Part => Body_Part)));
            end if;
         end if;

         ----------------------------------------------------------------------

         Rule := Rule_Up_Spec;

         --  This rule deals with upwards visibility, i.e. adding a link to
         --  the nearest "enclosing" scope. Generics are dealt with separately,
         --  except for generic child instantiations (they have visibility of
         --  their parent's instantiation).

         if not Info.Is_Instance then
            if Info.Is_Nested then
               Connect
                 (Spec_V,
                  Scope_Graph.Get_Vertex (Info.Container));

            elsif Info.Is_Private then
               Connect
                 (Spec_V,
                  Scope_Graph.Get_Vertex ((Ent  => Info.Parent,
                                           Part => Private_Part)));

            else
               --  ??? should this apply to instances too?
               Connect
                 (Spec_V,
                  Scope_Graph.Get_Vertex ((Ent  => Info.Parent,
                                           Part => Visible_Part)));
            end if;
         end if;

         ----------------------------------------------------------------------

         --  As mentioned before, instances break the chain so they need
         --  special treatment, and the remaining three rules just add the
         --  appropriate links. Note that although the last three are mutually
         --  exclusive, any of them might be an instance.

         ----------------------------------------------------------------------

         Rule := Rule_Down_Spec;

         --  This rule deals with downwards visibility, i.e. contributing to
         --  the set of things the parent can see. It is exactly the inverse
         --  of Rule_Own, except there is no special treatment for instances
         --  (since a scope does have visibility of the spec of something
         --  instantiated inside it).

         if Info.Is_Nested then
            Connect
              (Scope_Graph.Get_Vertex (Info.Container),
               Spec_V);
         elsif Info.Is_Private then
            Connect
              (Scope_Graph.Get_Vertex ((Ent  => Info.Parent,
                                        Part => Private_Part)),
               Spec_V);
         else
            Connect
              (Scope_Graph.Get_Vertex ((Ent  => Info.Parent,
                                        Part => Visible_Part)),
               Spec_V);
         end if;

         ----------------------------------------------------------------------

         Rule := Rule_Up_Priv;

         --  This rule deals with upwards visibility for the private part of a
         --  package. It is of course excepted by the "generic" rule.

         if Info.Is_Package then
            if Info.Is_Instance then
               Connect
                 (Priv_V,
                  Scope_Graph.Get_Vertex ((Ent  => Info.Template,
                                           Part => Private_Part)));
            elsif Is_Child (Info) then
               Connect
                 (Priv_V,
                  Scope_Graph.Get_Vertex ((Ent  => Info.Parent,
                                           Part => Private_Part)));
            end if;
         end if;

         ----------------------------------------------------------------------

         Rule := Rule_Up_Body;

         --  Finally, this rule deals with the upwards visibility for the body
         --  of a nested package. A nested scope will have visibility of its
         --  enclosing scope's body, since it is impossible to complete the
         --  body anywhere else. Again, there is an exception for the "generic"
         --  rule.

         if Info.Is_Instance then
            Connect
              (Body_V,
               Scope_Graph.Get_Vertex ((Ent  => Info.Template,
                                        Part => Body_Part)));
         elsif Info.Is_Nested then
            Connect
              (Body_V,
               Scope_Graph.Get_Vertex ((Ent  => Info.Container.Ent,
                                        Part => Body_Part)));
         end if;
      end Connect;

   --  Start of processing for Connect_Flow_Scopes

   begin
      for C in Hierarchy_Info.Iterate loop
         declare
            E    : Entity_Id renames Hierarchy_Info_Maps.Key (C);
            Info : Hierarchy_Info_T renames Hierarchy_Info (C);
         begin
            Connect (E, Info);
         end;
      end loop;

      --  Release memory to the provers
      Hierarchy_Info.Clear;

      Close_Visibility_Graph;
   end Connect_Flow_Scopes;

   ----------
   -- Hash --
   ----------

   function Hash (S : Flow_Scope) return Ada.Containers.Hash_Type is
      use type Ada.Containers.Hash_Type;
   begin
      --  Adding S.Part'Pos, which ranges from 0 to 3, should keep hash values
      --  unique, because S.Ent values of different scopes are not that close
      --  to each other.
      return Node_Hash (S.Ent) + Declarative_Part'Pos (S.Part);
   end Hash;

   --------------
   -- Is_Child --
   --------------

   function Is_Child (Info : Hierarchy_Info_T) return Boolean is
   begin
      return not Info.Is_Private
        and then not Info.Is_Nested
        and then Present (Info.Parent)
        and then Info.Parent /= Standard_Standard;
   end Is_Child;

   ----------------
   -- Is_Visible --
   ----------------

   function Is_Visible
     (Looking_From : Flow_Scope;
      Looking_At   : Flow_Scope)
      return Boolean
   is
   begin
      --  The visibility graph is not reflexive; we must explicitly check for
      --  visibility between the same scopes.

      return Looking_From = Looking_At
        or else Scope_Graph.Edge_Exists (Sanitize (Looking_From),
                                         Sanitize (Looking_At));
   end Is_Visible;

   ---------------
   -- Make_Info --
   ---------------

   function Make_Info (N : Node_Id) return Hierarchy_Info_T is
      Def_E : constant Entity_Id := Defining_Entity (N);

      E : constant Entity_Id :=
        (if Nkind (N) = N_Private_Type_Declaration
         then DIC_Procedure (Def_E)
         elsif Nkind (N) = N_Full_Type_Declaration
         then Invariant_Procedure (Def_E)
         else Def_E);

      Is_Package      : Boolean;
      --  Is_Child          : Boolean;
      Is_Private      : Boolean;
      Parent          : Entity_Id;
      Instance_Parent : Entity_Id;
      Template        : Entity_Id;

      Is_Nested       : Boolean;
      Container       : Flow_Scope;

      function Is_Text_IO_Special_Package (E : Entity_Id) return Boolean;
      --  Return True iff E is one of the special generic Text_IO packages,
      --  which Ada RM defines to be nested in Ada.Text_IO, but GNAT defines
      --  as its private children.

      --------------------------------
      -- Is_Text_IO_Special_Package --
      --------------------------------

      function Is_Text_IO_Special_Package (E : Entity_Id) return Boolean is
      begin
         --  ??? detection with a scope climbing might be more efficient

         for U in Ada_Text_IO_Child loop
            if Is_RTU (E, U) then
               return True;
            end if;
         end loop;

         for U in Ada_Wide_Text_IO_Child loop
            if Is_RTU (E, U) then
               return True;
            end if;
         end loop;

         for U in Ada_Wide_Wide_Text_IO_Child loop
            if Is_RTU (E, U) then
               return True;
            end if;
         end loop;

         return False;
      end Is_Text_IO_Special_Package;

   --  Start of processing for Make_Info

   begin
      --  Special Text_IO packages behave as nested within the Ada.Text_IO
      --  (that is what Ada RM A.10.1 mandates), but in GNAT they are defined
      --  as private generic children of Ada.Text_IO. We special-case them
      --  according to what the Ada RM says.

      if Ekind (E) in E_Package | E_Generic_Package then
         Is_Package := True;

         if Is_Child_Unit (E) then
            if Is_Text_IO_Special_Package (E) then
               Is_Private := False;
               Parent     := Empty;
            else
               Is_Private :=
                 Nkind (Atree.Parent (N)) = N_Compilation_Unit
                   and then
                 Private_Present (Atree.Parent (N));
               Parent     := Scope (E);
               pragma Assert (Hierarchy_Info.Contains (Parent));
            end if;
         elsif Get_Flow_Scope (N) = Null_Flow_Scope then
            Is_Private := False;
            Parent     := Standard_Standard;
         else
            Is_Private := False;
            Parent     := Empty;
         end if;

      else
         pragma Assert (Ekind (E) in Entry_Kind
                                   | E_Function
                                   | E_Procedure
                                   | E_Protected_Type
                                   | E_Task_Type
                                   | Generic_Subprogram_Kind);

         Is_Package := False;
         Is_Private := False;

         if Is_Compilation_Unit (E) then
            if Ekind (E) in E_Function | E_Procedure
              and then Is_Generic_Instance (E)
            then
               Parent := Empty;
            else
               Parent := Scope (E);
            end if;
         else
            Parent := Empty;
         end if;
      end if;

      if Is_Generic_Instance (E) then
         Template := Generic_Parent (Specification (N));

         --  Deal with instances of child instances; this is based on frontend
         --  Install_Parent_Private_Declarations.

         if Is_Child_Unit (Template)
           and then Is_Generic_Unit (Scope (Template))
         then
            declare
               Inst_Node : constant Node_Id := Get_Unit_Instantiation_Node (E);

            begin
               pragma Assert (Nkind (Inst_Node) = N_Package_Instantiation);
               --  The original frontend routine expects formal packages too,
               --  but apparently here we only get package instantiations.

               case Nkind (Name (Inst_Node)) is
                  when N_Identifier =>
                     raise Program_Error
                       with "generic parent with generic child";
                     --  ??? This happens when instantiating the generic child
                     --  within the parent's instance body; see acats ca11021.
                     --  The original frontend routine doesn't deal with this
                     --  case; currently just crash.

                  when N_Expanded_Name =>
                     Instance_Parent := Entity (Prefix (Name (Inst_Node)));

                     pragma Assert
                       (Ekind (Instance_Parent) = E_Package);

                  when others =>
                     raise Program_Error;
               end case;

               if Present (Renamed_Entity (Instance_Parent)) then
                  Instance_Parent := Renamed_Entity (Instance_Parent);
               end if;
            end;
         else
            Instance_Parent := Empty;
         end if;
      else
         Template        := Empty;
         Instance_Parent := Empty;
      end if;

      if Is_Child_Unit (E)
        and then Is_Text_IO_Special_Package (E)
      then
         Container := (Ent => Scope (E), Part => Visible_Part);
         Is_Nested := True;
      else
         Container := Get_Flow_Scope (N);
         Is_Nested := Container /= Null_Flow_Scope;
      end if;

      -------------------------------------------------------------------------
      --  Invariant
      --
      --  This is intentonally a sequance of pragmas and not a Boolean-value
      --  function, because with pragmas if one of the conditions fails, it
      --  is easier to know which one.
      -------------------------------------------------------------------------

      pragma Assert (if not Is_Package then not Is_Private);
      --  ??? how about private functions and procedures?

      pragma Assert (if Is_Private then not Is_Nested);

      pragma Assert
       (if Is_Nested then
          not Is_Private
          and then No (Parent)
          and then Container /= Null_Flow_Scope
        else
          Present (Parent)
          and then Container = Null_Flow_Scope);

      -------------------------------------------------------------------------

      return (Is_Package        => Is_Package,
--              Is_Child          => Is_Child,
              Is_Private        => Is_Private,
              Is_Nested         => Is_Nested,
              Is_Instance       => Present (Template),
              Is_Instance_Child => Present (Instance_Parent),
              Parent            => Parent,
              Instance_Parent   => Instance_Parent,
              Template          => Template,
              Container         => Container);
   end Make_Info;

   -----------
   -- Print --
   -----------

   procedure Print (G : Scope_Graphs.Graph)
   is
      use Scope_Graphs;

      function NDI (G : Graph; V : Vertex_Id) return Node_Display_Info;
      --  Pretty-printing for vertices in the dot output

      function EDI
        (G      : Graph;
         A      : Vertex_Id;
         B      : Vertex_Id;
         Marked : Boolean;
         Colour : Edge_Kind) return Edge_Display_Info;
      --  Pretty-printing for edges in the dot output

      ---------
      -- NDI --
      ---------

      function NDI (G : Graph; V : Vertex_Id) return Node_Display_Info
      is
         S : constant Flow_Scope := G.Get_Key (V);

         Label : constant String :=
           Full_Source_Name (S.Ent) &
         (case S.Part is
             when Visible_Part => " (Spec)",
             when Private_Part => " (Priv)",
             when Body_Part    => " (Body)",
             when Null_Part    => raise Program_Error);

      begin
         return (Show        => True,
                 Shape       => Shape_None,
                 Colour      =>
                   To_Unbounded_String
                     (if S = Standard_Scope         then "blue"
                      elsif Is_Generic_Unit (S.Ent) then "red"
                      else ""),
                 Fill_Colour => Null_Unbounded_String,
                 Label       => To_Unbounded_String (Label));
      end NDI;

      ---------
      -- EDI --
      ---------

      function EDI
        (G      : Graph;
         A      : Vertex_Id;
         B      : Vertex_Id;
         Marked : Boolean;
         Colour : Edge_Kind) return Edge_Display_Info
      is
         pragma Unreferenced (G, A, B, Marked, Colour);

      begin
         return
           (Show   => True,
            Shape  => Edge_Normal,
            Colour => Null_Unbounded_String,
            Label  => Null_Unbounded_String);
         --  ??? Label should reflect the Colour argument, but the current
         --  names of the rules are too long and produce unreadable graphs.
      end EDI;

      Filename : constant String :=
        Unique_Name (Main_Unit_Entity) & "_visibility";

   --  Start of processing for Print

   begin
      G.Write_Pdf_File
        (Filename  => Filename,
         Node_Info => NDI'Access,
         Edge_Info => EDI'Access);
   end Print;

   ----------------
   -- Print_Path --
   ----------------

   procedure Print_Path (From, To : Flow_Scope) is

      Source : constant Scope_Graphs.Vertex_Id :=
        Raw_Scope_Graph.Get_Vertex (Sanitize (From));

      Target : constant Scope_Graphs.Vertex_Id :=
        Raw_Scope_Graph.Get_Vertex (Sanitize (To));

      procedure Is_Target
        (V           : Scope_Graphs.Vertex_Id;
         Instruction : out Scope_Graphs.Traversal_Instruction);

      procedure Print_Vertex (V : Scope_Graphs.Vertex_Id);

      ---------------
      -- Is_Target --
      ---------------

      procedure Is_Target
        (V           : Scope_Graphs.Vertex_Id;
         Instruction : out Scope_Graphs.Traversal_Instruction)
      is
         use type Scope_Graphs.Vertex_Id;
      begin
         Instruction :=
           (if V = Target
            then Scope_Graphs.Found_Destination
            else Scope_Graphs.Continue);
      end Is_Target;

      ------------------
      -- Print_Vertex --
      ------------------

      procedure Print_Vertex (V : Scope_Graphs.Vertex_Id) is
         S : constant Flow_Scope := Raw_Scope_Graph.Get_Key (V);
      begin
         --  Print_Flow_Scope (S);
         --  ??? the above code produces no output in gdb; use Ada.Text_IO

         if Present (S.Ent) then
            Ada.Text_IO.Put_Line
              (Full_Source_Name (S.Ent) &
                 " | " &
               (case Declarative_Part'(S.Part) is
                     when Visible_Part => "spec",
                     when Private_Part => "priv",
                     when Body_Part    => "body"));
         else
            Ada.Text_IO.Put_Line ("standard");
         end if;
      end Print_Vertex;

   --  Start of processing for Print_Path

   begin
      Scope_Graphs.Shortest_Path
        (G             => Raw_Scope_Graph,
         Start         => Source,
         Allow_Trivial => True,
         Search        => Is_Target'Access,
         Step          => Print_Vertex'Access);
   end Print_Path;

   --------------------------
   -- Register_Flow_Scopes --
   --------------------------

   procedure Register_Flow_Scopes (Unit_Node : Node_Id) is
      procedure Processx (N : Node_Id)
      with Pre => Nkind (N) in N_Entry_Declaration
                             | N_Generic_Declaration
                             | N_Package_Declaration
                             | N_Protected_Type_Declaration
                             | N_Subprogram_Declaration
                             | N_Subprogram_Body_Stub
                             | N_Task_Type_Declaration
                  or else (Nkind (N) = N_Subprogram_Body
                           and then Acts_As_Spec (N))
                  or else (Nkind (N) = N_Private_Type_Declaration
                           and then Has_Own_DIC (Defining_Entity (N)))
                  or else (Nkind (N) = N_Full_Type_Declaration
                           and then Has_Own_Invariants (Defining_Entity (N)));
      --  ??? remove the "x" suffix once debugging is done

      -------------
      -- Process --
      -------------

      procedure Processx (N : Node_Id) is
         Def_E : constant Entity_Id := Defining_Entity (N);

         E : constant Entity_Id :=
           (if Nkind (N) = N_Private_Type_Declaration
            then DIC_Procedure (Def_E)
            elsif Nkind (N) = N_Full_Type_Declaration
            then Invariant_Procedure (Def_E)
            else Def_E);

         Info : constant Hierarchy_Info_T := Make_Info (N);

         Spec_V, Priv_V, Body_V : Scope_Graphs.Vertex_Id;
         --  Vertices for the visible (aka. "spec"), private and body parts

      begin
         --  ??? we don't need this info (except for debug?)

         Hierarchy_Info.Insert (E, Info);

         ----------------------------------------------------------------------
         --  Create vertices
         ----------------------------------------------------------------------

         Scope_Graph.Add_Vertex ((Ent => E, Part => Visible_Part), Spec_V);

         if Info.Is_Package then
            Scope_Graph.Add_Vertex ((Ent => E, Part => Private_Part), Priv_V);
         end if;

         Scope_Graph.Add_Vertex ((Ent => E, Part => Body_Part), Body_V);
      end Processx;

      procedure Traverse is new Traverse_Compilation_Unit (Processx);

   --  Start of processing for Build_Graph

   begin
      if Unit_Node = Standard_Package_Node then
         Scope_Graph.Add_Vertex (Standard_Scope);
      else
         Traverse (Unit_Node);
      end if;
   end Register_Flow_Scopes;

   -------------------------------
   -- Traverse_Compilation_Unit --
   -------------------------------

   procedure Traverse_Compilation_Unit (Unit_Node : Node_Id)
   is
      procedure Traverse_Declaration_Or_Statement   (N : Node_Id);
      procedure Traverse_Declarations_And_HSS       (N : Node_Id);
      procedure Traverse_Declarations_Or_Statements (L : List_Id);
      procedure Traverse_Handled_Statement_Sequence (N : Node_Id);
      procedure Traverse_Package_Body               (N : Node_Id);
      procedure Traverse_Visible_And_Private_Parts  (N : Node_Id);
      procedure Traverse_Protected_Body             (N : Node_Id);
      procedure Traverse_Subprogram_Body            (N : Node_Id);
      procedure Traverse_Task_Body                  (N : Node_Id);

      --  Traverse corresponding construct, calling Process on all declarations

      ---------------------------------------
      -- Traverse_Declaration_Or_Statement --
      ---------------------------------------

      procedure Traverse_Declaration_Or_Statement (N : Node_Id) is
      begin
         --  Call Process on all interesting declarations and traverse

         case Nkind (N) is
            when N_Package_Declaration
               | N_Generic_Package_Declaration
            =>
               Process (N);
               Traverse_Visible_And_Private_Parts (Specification (N));

            when N_Package_Body =>
               Traverse_Package_Body (N);

            when N_Package_Body_Stub =>
               Traverse_Package_Body (Get_Body_From_Stub (N));

            when N_Entry_Declaration
               | N_Generic_Subprogram_Declaration
               | N_Subprogram_Declaration
            =>
               Process (N);

            when N_Subprogram_Body =>
               if Acts_As_Spec (N) then
                  Process (N);
               end if;

               Traverse_Subprogram_Body (N);

            when N_Entry_Body =>
               Traverse_Subprogram_Body (N);

            when N_Subprogram_Body_Stub =>
               if Is_Subprogram_Stub_Without_Prior_Declaration (N) then
                  Process (N);
               end if;

               Traverse_Subprogram_Body (Get_Body_From_Stub (N));

            when N_Protected_Body =>
               Traverse_Protected_Body (N);

            when N_Protected_Body_Stub =>
               Traverse_Protected_Body (Get_Body_From_Stub (N));

            when N_Protected_Type_Declaration =>
               Process (N);
               Traverse_Visible_And_Private_Parts (Protected_Definition (N));

            when N_Task_Type_Declaration =>

               Process (N);

               --  Task type definition is optional (unlike protected type
               --  definition, which is mandatory).

               declare
                  Task_Def : constant Node_Id := Task_Definition (N);

               begin
                  if Present (Task_Def) then
                     Traverse_Visible_And_Private_Parts (Task_Def);
                  end if;
               end;

            when N_Task_Body =>
               Traverse_Task_Body (N);

            when N_Task_Body_Stub =>
               Traverse_Task_Body (Get_Body_From_Stub (N));

            when N_Block_Statement =>
               Traverse_Declarations_And_HSS (N);

            when N_If_Statement =>

               --  Traverse the statements in the THEN part

               Traverse_Declarations_Or_Statements (Then_Statements (N));

               --  Loop through ELSIF parts if present

               if Present (Elsif_Parts (N)) then
                  declare
                     Elif : Node_Id := First (Elsif_Parts (N));

                  begin
                     while Present (Elif) loop
                        Traverse_Declarations_Or_Statements
                          (Then_Statements (Elif));
                        Next (Elif);
                     end loop;
                  end;
               end if;

               --  Finally traverse the ELSE statements if present

               Traverse_Declarations_Or_Statements (Else_Statements (N));

            when N_Case_Statement =>

               --  Process case branches

               declare
                  Alt : Node_Id := First (Alternatives (N));

               begin
                  loop
                     Traverse_Declarations_Or_Statements (Statements (Alt));
                     Next (Alt);
                     exit when No (Alt);
                  end loop;
               end;

            when N_Extended_Return_Statement =>
               Traverse_Handled_Statement_Sequence
                 (Handled_Statement_Sequence (N));

            when N_Loop_Statement =>
               Traverse_Declarations_Or_Statements (Statements (N));

            when N_Private_Type_Declaration =>
               --  Both private and full view declarations might be represented
               --  by N_Private_Type_Declaration; the former comes from source,
               --  the latter comes from rewriting.

               if Comes_From_Source (N) then
                  declare
                     T : constant Entity_Id := Defining_Entity (N);

                  begin
                     if Has_Own_DIC (T)
                       and then Present (DIC_Procedure (T))
                     then
                        Process (N);
                     end if;
                  end;
               end if;

            when N_Full_Type_Declaration =>
               declare
                  T : constant Entity_Id := Defining_Entity (N);

               begin
                  --  For Type_Invariant'Class there will be no invariant
                  --  procedure; we ignore it, because this aspect is not
                  --  supported in SPARK anyway.

                  if Has_Own_Invariants (T)
                    and then Present (Invariant_Procedure (T))
                  then
                     Process (N);
                  end if;
               end;

            when others =>
               null;
         end case;
      end Traverse_Declaration_Or_Statement;

      -----------------------------------
      -- Traverse_Declarations_And_HSS --
      -----------------------------------

      procedure Traverse_Declarations_And_HSS (N : Node_Id) is
      begin
         Traverse_Declarations_Or_Statements (Declarations (N));
         Traverse_Handled_Statement_Sequence (Handled_Statement_Sequence (N));
      end Traverse_Declarations_And_HSS;

      -----------------------------------------
      -- Traverse_Declarations_Or_Statements --
      -----------------------------------------

      procedure Traverse_Declarations_Or_Statements (L : List_Id) is
         N : Node_Id := First (L);

      begin
         --  Loop through statements or declarations

         while Present (N) loop
            Traverse_Declaration_Or_Statement (N);
            Next (N);
         end loop;
      end Traverse_Declarations_Or_Statements;

      -----------------------------------------
      -- Traverse_Handled_Statement_Sequence --
      -----------------------------------------

      procedure Traverse_Handled_Statement_Sequence (N : Node_Id) is
         Handler : Node_Id;

      begin
         if Present (N) then
            Traverse_Declarations_Or_Statements (Statements (N));

            if Present (Exception_Handlers (N)) then
               Handler := First (Exception_Handlers (N));
               while Present (Handler) loop
                  Traverse_Declarations_Or_Statements (Statements (Handler));
                  Next (Handler);
               end loop;
            end if;
         end if;
      end Traverse_Handled_Statement_Sequence;

      ---------------------------
      -- Traverse_Package_Body --
      ---------------------------

      procedure Traverse_Package_Body (N : Node_Id) is
      begin
         Traverse_Declarations_Or_Statements (Declarations (N));
         Traverse_Handled_Statement_Sequence (Handled_Statement_Sequence (N));
      end Traverse_Package_Body;

      -----------------------------
      -- Traverse_Protected_Body --
      -----------------------------

      procedure Traverse_Protected_Body (N : Node_Id) is
      begin
         Traverse_Declarations_Or_Statements (Declarations (N));
      end Traverse_Protected_Body;

      ------------------------------
      -- Traverse_Subprogram_Body --
      ------------------------------

      procedure Traverse_Subprogram_Body (N : Node_Id) renames
         Traverse_Declarations_And_HSS;

      ------------------------
      -- Traverse_Task_Body --
      ------------------------

      procedure Traverse_Task_Body (N : Node_Id) renames
         Traverse_Declarations_And_HSS;

      ----------------------------------------
      -- Traverse_Visible_And_Private_Parts --
      ----------------------------------------

      procedure Traverse_Visible_And_Private_Parts (N : Node_Id) is
      begin
         Traverse_Declarations_Or_Statements (Visible_Declarations (N));
         Traverse_Declarations_Or_Statements (Private_Declarations (N));
      end Traverse_Visible_And_Private_Parts;

   --  Start of processing for Traverse_Compilation_Unit

   begin
      Traverse_Declaration_Or_Statement (Unit_Node);
   end Traverse_Compilation_Unit;

end Flow_Visibility;