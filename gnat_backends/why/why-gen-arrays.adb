------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                        W H Y - G E N - A R R A Y S                       --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                       Copyright (C) 2010-2011, AdaCore                   --
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
-- gnat2why is maintained by AdaCore (http://www.adacore.com)               --
--                                                                          --
------------------------------------------------------------------------------

with VC_Kinds;           use VC_Kinds;
with Why.Conversions;    use Why.Conversions;
with Why.Atree.Builders; use Why.Atree.Builders;
with Why.Gen.Decl;       use Why.Gen.Decl;
with Why.Gen.Expr;       use Why.Gen.Expr;
with Why.Gen.Names;      use Why.Gen.Names;
with Why.Gen.Binders;    use Why.Gen.Binders;
with Why.Types;          use Why.Types;

package body Why.Gen.Arrays is

   -----------------------------------
   -- Declare_Ada_Constrained_Array --
   -----------------------------------

   procedure Declare_Ada_Constrained_Array
     (File      : W_File_Sections;
      Name      : String;
      Component : String;
      First     : W_Term_Id;
      Last      : W_Term_Id)
   is
      Ar         : constant W_Term_Id :=
                     New_Term ("a");
      Ar_Binder  : constant Binder_Type :=
                     (B_Name => New_Identifier ("a"),
                      B_Type =>
                        New_Abstract_Type
                          (Name => (New_Identifier (Name))),
                      others => <>);
   begin
      Declare_Ada_Unconstrained_Array (File, Name, Component);

      --  State axioms about fixed 'First, 'Last and 'Length

      if First /= Why_Empty then
         Emit
           (File (W_File_Axiom),
            New_Guarded_Axiom
              (Name => Array_First_Static.Id (Name),
               Binders => (1 => Ar_Binder),
               Def =>
                 New_Relation
                   (Op      => EW_Eq,
                    Op_Type => EW_Int,
                    Left    =>
                      +New_Array_Attr
                        (Attr_First,
                         Name,
                         +Ar,
                         EW_Term),
                    Right   => +First)));
      end if;
      if Last /= Why_Empty then
         Emit
           (File (W_File_Axiom),
            New_Guarded_Axiom
              (Name => Array_Last_Static.Id (Name),
               Binders => (1 => Ar_Binder),
               Def =>
                 New_Relation
                   (Op      => EW_Eq,
                    Op_Type => EW_Int,
                    Left    =>
                      +New_Array_Attr
                        (Attr_Last,
                         Name,
                         +Ar,
                         EW_Term),
                    Right   => +Last)));
      end if;
      --  Emit
      --    (File,
      --     New_Guarded_Axiom
      --       (Name => Array_Length_Static.Id (Name),
      --        Binders => (1 => Ar_Binder),
      --        Def =>
      --          New_Relation
      --            (Op      => EW_Eq,
      --             Op_Type => EW_Int,
      --             Left    =>
      --               +New_Array_Attr
      --                 (Attr_Length,
      --                  Name,
      --                  +Ar,
      --                  EW_Term),
      --             Right   =>
      --               New_Integer_Constant
      --                 (Value => UI_Add (UI_Sub (Last, First), 1)))));
   end Declare_Ada_Constrained_Array;

   -------------------------------------
   -- Declare_Ada_Unconstrained_Array --
   -------------------------------------

   procedure Declare_Ada_Unconstrained_Array
     (File      : W_File_Sections;
      Name      : String;
      Component : String)
   is
      Comp_Type  : constant W_Primitive_Type_Id :=
                     New_Abstract_Type
                       (Name => (New_Identifier (Component)));
      Ar_Type    : constant W_Primitive_Type_Id :=
                     New_Generic_Actual_Type_Chain
                       (Type_Chain => (1 => Comp_Type),
                        Name       => New_Identifier (Ada_Array));
      Name_Type  : constant W_Primitive_Type_Id :=
                     New_Abstract_Type
                       (Name => (New_Identifier (Name)));
      Ar         : constant W_Term_Id := New_Term ("a");
      Arb        : constant W_Term_Id := New_Term ("b");
      Ar_Binder_2 : constant Binder_Type :=
                      (B_Name => New_Identifier ("a"),
                       B_Type => Ar_Type,
                       others => <>);
   begin
      --  generate the theory:
      --  type t
      --  logic to_ : t -> comp ada_array
      --  logic from_ : comp ada_array -> t
      --  axiom 1 : forall x, to_ (from_ (x)) = x
      --  axiom 2 : forall x, y, to_ (x) = to_ (y) -> x = y
      --  ??? why-gen-axioms defines general methods to
      --  generate these axioms. Presumably not exactly those ones,
      --  but close enough. This should be factorized out.
      Emit (File (W_File_Logic_Type), New_Type (Name));
      Emit
        (File (W_File_Logic_Type),
         New_Function_Decl
           (Domain      => EW_Term,
            Name        => Array_Conv_From.Id (Name),
            Binders     => New_Binders ((1 => Name_Type)),
            Return_Type => Ar_Type));
      Emit
        (File (W_File_Logic_Type),
         New_Function_Decl
           (Domain      => EW_Term,
            Name        => Array_Conv_To.Id (Name),
            Binders     => (1 => Ar_Binder_2),
            Return_Type => Name_Type));
      Emit
        (File (W_File_Logic_Type),
         New_Axiom
           (Name => Array_Conv_Idem.Id (Name),
            Def  =>
              New_Universal_Quantif
                (Var_Type  =>
                   New_Abstract_Type
                     (Name => (New_Identifier (Name))),
                 Variables => (1 => New_Identifier ("a")),
                 Triggers  => New_Triggers
                   (Triggers =>
                      (1 =>
                         New_Trigger
                           (Terms =>
                              (1 =>
                                 New_Call
                                   (Name => Array_Conv_From.Id (Name),
                                    Args => (1 => +Ar)))))),
                 Pred      =>
                   New_Relation
                     (Op      => EW_Eq,
                      Op_Type => EW_Abstract,
                      Left    => +Ar,
                      Right   =>
                        New_Call
                          (Domain => EW_Term,
                           Name   => Array_Conv_To.Id (Name),
                           Args   =>
                             (1 =>
                                New_Call
                                  (Domain => EW_Term,
                                   Name   => Array_Conv_From.Id (Name),
                                   Args   => (1 => +Ar))))))));
      Emit
        (File (W_File_Logic_Type),
         New_Guarded_Axiom
           (Name    => Array_Conv_Idem_2.Id (Name),
            Binders => (1 => Ar_Binder_2),
            Def     =>
              New_Universal_Quantif
                (Var_Type  => +Ar_Type,
                 Variables => (1 => New_Identifier ("b")),
                 Triggers  =>
                   New_Triggers
                     (Triggers =>
                       (1 =>
                          New_Trigger
                            (Terms =>
                               (1 =>
                                  New_Call
                                    (Name => Array_Conv_To.Id (Name),
                                     Args => (1 => +Ar)),
                                2 =>
                                  New_Call
                                    (Name => Array_Conv_To.Id (Name),
                                     Args => (1 => +Arb)))))),
                 Pred      =>
                   New_Connection
                     (Op     => EW_Imply,
                      Left   =>
                        New_Relation
                          (Domain  => EW_Pred,
                           Op      => EW_Eq,
                           Op_Type => EW_Abstract,
                           Left    =>
                             New_Call
                               (Domain => EW_Term,
                                Name   => Array_Conv_To.Id (Name),
                                Args   => (1 => +Ar)),
                           Right =>
                             New_Call
                               (Domain => EW_Term,
                                Name   => Array_Conv_To.Id (Name),
                                Args   => (1 => +Arb))),
                      Right  =>
                        New_Relation
                          (Domain  => EW_Pred,
                           Op      => EW_Eq,
                           Op_Type => EW_Abstract,
                           Left    => +Ar,
                           Right   => +Arb)))));
   end Declare_Ada_Unconstrained_Array;

   ----------------------
   -- New_Array_Access --
   ----------------------

   function New_Array_Access
     (Ada_Node      : Node_Id;
      Type_Name     : String;
      Ar            : W_Expr_Id;
      Index         : W_Expr_Id;
      Domain        : EW_Domain) return W_Expr_Id
   is
      Name      : constant W_Identifier_Id := Array_Access_Name.Id (Ada_Array);
      Used_Name : constant W_Identifier_Id :=
         (if Domain = EW_Prog then To_Program_Space (Name) else Name);
   begin
      return
         +New_Located_Call
            (Ada_Node => Ada_Node,
             Reason   => VC_Array_Bounds_Check,
             Name     => Used_Name,
             Domain   => Domain,
             Progs    =>
               (1 => +Index,
                2 =>
                  New_Call
                    (Domain => Domain,
                     Name   => Array_Conv_From.Id (Type_Name),
                     Args   => (1 => +Ar))));
   end New_Array_Access;

   --------------------
   -- New_Array_Attr --
   --------------------

   function New_Array_Attr
      (Name      : String;
       Type_Name : String;
       Ar        : W_Expr_Id;
       Domain    : EW_Domain) return W_Expr_Id
   is
   begin
      return
        New_Call
          (Domain => Domain,
           Name   => Attr_Name.Id (Ada_Array, Name),
           Args   =>
            (1 =>
               New_Call
                 (Domain => Domain,
                  Name   => Array_Conv_From.Id (Type_Name),
                  Args   => (1 => +Ar))));
   end New_Array_Attr;

   ----------------------
   -- New_Array_Update --
   ----------------------

   function New_Array_Update
      (Ada_Node  : Node_Id;
       Type_Name : String;
       Ar        : W_Expr_Id;
       Index     : W_Expr_Id;
       Value     : W_Expr_Id;
       Domain    : EW_Domain) return W_Expr_Id
   is
      Name : constant W_Identifier_Id := Array_Update_Name.Id (Ada_Array);
      Used_Name : constant W_Identifier_Id :=
         (if Domain = EW_Prog then To_Program_Space (Name) else Name);
      Array_Upd : constant W_Expr_Id :=
         New_Located_Call
           (Ada_Node => Ada_Node,
            Domain => Domain,
            Reason => VC_Array_Bounds_Check,
            Name   => Used_Name,
            Progs   =>
              (1 => +Index,
               2 => New_Call
                       (Domain => Domain,
                        Name   => Array_Conv_From.Id (Type_Name),
                        Args   => (1 => +Ar)),
              3 => +Value));
   begin
      return
        New_Call
          (Name   => Array_Conv_To.Id (Type_Name),
           Args   => (1 => Array_Upd),
           Domain => Domain);
   end New_Array_Update;

end Why.Gen.Arrays;
