export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type Database = {
  authz: {
    Tables: {
      access_assignments: {
        Row: {
          created_at: string;
          created_by_user_id: string;
          id: string;
          reason: string;
          revoked_at: string | null;
          revoked_by_user_id: string | null;
          subject_user_id: string;
          tenant_id: string;
        };
        Insert: {
          created_at?: string;
          created_by_user_id: string;
          id?: string;
          reason: string;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          subject_user_id: string;
          tenant_id: string;
        };
        Update: {
          created_at?: string;
          created_by_user_id?: string;
          id?: string;
          reason?: string;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          subject_user_id?: string;
          tenant_id?: string;
        };
        Relationships: [];
      };
      access_command_idempotency: {
        Row: {
          actor_user_id: string;
          assignment_id: string;
          command_type: string;
          created_at: string;
          idempotency_key: string;
          request_fingerprint: string;
        };
        Insert: {
          actor_user_id: string;
          assignment_id: string;
          command_type: string;
          created_at?: string;
          idempotency_key: string;
          request_fingerprint: string;
        };
        Update: {
          actor_user_id?: string;
          assignment_id?: string;
          command_type?: string;
          created_at?: string;
          idempotency_key?: string;
          request_fingerprint?: string;
        };
        Relationships: [
          {
            foreignKeyName: "access_command_idempotency_assignment_id_fkey";
            columns: ["assignment_id"];
            isOneToOne: false;
            referencedRelation: "access_assignments";
            referencedColumns: ["id"];
          },
        ];
      };
      access_rules: {
        Row: {
          assignment_id: string;
          created_at: string;
          effect: Database["authz"]["Enums"]["access_effect"];
          expires_at: string | null;
          id: string;
          permission_key: string;
          revoked_at: string | null;
          revoked_by_user_id: string | null;
          scope_membership_id: string | null;
          scope_office_id: string | null;
          scope_type: Database["authz"]["Enums"]["access_scope_type"];
          starts_at: string;
          tenant_id: string;
        };
        Insert: {
          assignment_id: string;
          created_at?: string;
          effect: Database["authz"]["Enums"]["access_effect"];
          expires_at?: string | null;
          id?: string;
          permission_key: string;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          scope_membership_id?: string | null;
          scope_office_id?: string | null;
          scope_type: Database["authz"]["Enums"]["access_scope_type"];
          starts_at?: string;
          tenant_id: string;
        };
        Update: {
          assignment_id?: string;
          created_at?: string;
          effect?: Database["authz"]["Enums"]["access_effect"];
          expires_at?: string | null;
          id?: string;
          permission_key?: string;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          scope_membership_id?: string | null;
          scope_office_id?: string | null;
          scope_type?: Database["authz"]["Enums"]["access_scope_type"];
          starts_at?: string;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "access_rules_permission_key_fkey";
            columns: ["permission_key"];
            isOneToOne: false;
            referencedRelation: "permission_catalog";
            referencedColumns: ["permission_key"];
          },
          {
            foreignKeyName: "access_rules_tenant_id_assignment_id_fkey";
            columns: ["tenant_id", "assignment_id"];
            isOneToOne: false;
            referencedRelation: "access_assignments";
            referencedColumns: ["tenant_id", "id"];
          },
        ];
      };
      account_status_command_idempotency: {
        Row: {
          actor_user_id: string;
          created_at: string;
          idempotency_key: string;
          request_fingerprint: string;
          target_user_id: string;
        };
        Insert: {
          actor_user_id: string;
          created_at?: string;
          idempotency_key: string;
          request_fingerprint: string;
          target_user_id: string;
        };
        Update: {
          actor_user_id?: string;
          created_at?: string;
          idempotency_key?: string;
          request_fingerprint?: string;
          target_user_id?: string;
        };
        Relationships: [];
      };
      action_confirmations: {
        Row: {
          action_key: string;
          confirmed_at: string;
          consumed_at: string | null;
          expires_at: string;
          id: string;
          session_id: string;
          target_id: string | null;
          target_type: string;
          user_id: string;
        };
        Insert: {
          action_key: string;
          confirmed_at?: string;
          consumed_at?: string | null;
          expires_at: string;
          id?: string;
          session_id: string;
          target_id?: string | null;
          target_type: string;
          user_id: string;
        };
        Update: {
          action_key?: string;
          confirmed_at?: string;
          consumed_at?: string | null;
          expires_at?: string;
          id?: string;
          session_id?: string;
          target_id?: string | null;
          target_type?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "action_confirmations_session_id_fkey";
            columns: ["session_id"];
            isOneToOne: false;
            referencedRelation: "elevated_sessions";
            referencedColumns: ["session_id"];
          },
        ];
      };
      default_role_permissions: {
        Row: {
          permission_key: string;
          role_key: Database["public"]["Enums"]["role_key"];
        };
        Insert: {
          permission_key: string;
          role_key: Database["public"]["Enums"]["role_key"];
        };
        Update: {
          permission_key?: string;
          role_key?: Database["public"]["Enums"]["role_key"];
        };
        Relationships: [
          {
            foreignKeyName: "default_role_permissions_permission_key_fkey";
            columns: ["permission_key"];
            isOneToOne: false;
            referencedRelation: "permission_catalog";
            referencedColumns: ["permission_key"];
          },
        ];
      };
      elevated_sessions: {
        Row: {
          factor_method: string;
          revoked_at: string | null;
          session_id: string;
          user_id: string;
          valid_until: string;
          verified_at: string;
        };
        Insert: {
          factor_method: string;
          revoked_at?: string | null;
          session_id: string;
          user_id: string;
          valid_until: string;
          verified_at: string;
        };
        Update: {
          factor_method?: string;
          revoked_at?: string | null;
          session_id?: string;
          user_id?: string;
          valid_until?: string;
          verified_at?: string;
        };
        Relationships: [];
      };
      financial_evidence_reviewer_assignments: {
        Row: {
          assigned_at: string;
          assigned_by_user_id: string;
          id: string;
          reviewer_membership_id: string;
          reviewer_user_id: string;
          revoked_at: string | null;
          revoked_by_user_id: string | null;
          tenant_id: string;
        };
        Insert: {
          assigned_at?: string;
          assigned_by_user_id: string;
          id?: string;
          reviewer_membership_id: string;
          reviewer_user_id: string;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          tenant_id: string;
        };
        Update: {
          assigned_at?: string;
          assigned_by_user_id?: string;
          id?: string;
          reviewer_membership_id?: string;
          reviewer_user_id?: string;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          tenant_id?: string;
        };
        Relationships: [];
      };
      office_closure: {
        Row: {
          ancestor_office_id: string;
          depth: number;
          descendant_office_id: string;
          tenant_id: string;
        };
        Insert: {
          ancestor_office_id: string;
          depth: number;
          descendant_office_id: string;
          tenant_id: string;
        };
        Update: {
          ancestor_office_id?: string;
          depth?: number;
          descendant_office_id?: string;
          tenant_id?: string;
        };
        Relationships: [];
      };
      permission_catalog: {
        Row: {
          area: string;
          blocked_during_commercial_restriction: boolean;
          can_target_own_wallet: boolean;
          default_scope_mode: string;
          grantable: boolean;
          permission_key: string;
          protected: boolean;
          step_up_mode: Database["authz"]["Enums"]["required_auth_level"];
          wallet_holder_baseline: boolean;
        };
        Insert: {
          area: string;
          blocked_during_commercial_restriction?: boolean;
          can_target_own_wallet: boolean;
          default_scope_mode: string;
          grantable: boolean;
          permission_key: string;
          protected: boolean;
          step_up_mode?: Database["authz"]["Enums"]["required_auth_level"];
          wallet_holder_baseline: boolean;
        };
        Update: {
          area?: string;
          blocked_during_commercial_restriction?: boolean;
          can_target_own_wallet?: boolean;
          default_scope_mode?: string;
          grantable?: boolean;
          permission_key?: string;
          protected?: boolean;
          step_up_mode?: Database["authz"]["Enums"]["required_auth_level"];
          wallet_holder_baseline?: boolean;
        };
        Relationships: [];
      };
      platform_admin_users: {
        Row: {
          granted_at: string;
          granted_by_user_id: string | null;
          revoked_at: string | null;
          revoked_by_user_id: string | null;
          user_id: string;
        };
        Insert: {
          granted_at?: string;
          granted_by_user_id?: string | null;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          user_id: string;
        };
        Update: {
          granted_at?: string;
          granted_by_user_id?: string | null;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          user_id?: string;
        };
        Relationships: [];
      };
      security_audit_events: {
        Row: {
          actor_user_id: string | null;
          allowed: boolean | null;
          event_type: string;
          id: number;
          metadata: Json;
          occurred_at: string;
          permission_key: string | null;
          reason_code: string | null;
          session_id: string | null;
          source: Database["authz"]["Enums"]["authorization_source"] | null;
          source_id: string | null;
          target_id: string | null;
          target_type: string | null;
          tenant_id: string | null;
        };
        Insert: {
          actor_user_id?: string | null;
          allowed?: boolean | null;
          event_type: string;
          id?: never;
          metadata?: Json;
          occurred_at?: string;
          permission_key?: string | null;
          reason_code?: string | null;
          session_id?: string | null;
          source?: Database["authz"]["Enums"]["authorization_source"] | null;
          source_id?: string | null;
          target_id?: string | null;
          target_type?: string | null;
          tenant_id?: string | null;
        };
        Update: {
          actor_user_id?: string | null;
          allowed?: boolean | null;
          event_type?: string;
          id?: never;
          metadata?: Json;
          occurred_at?: string;
          permission_key?: string | null;
          reason_code?: string | null;
          session_id?: string | null;
          source?: Database["authz"]["Enums"]["authorization_source"] | null;
          source_id?: string | null;
          target_id?: string | null;
          target_type?: string | null;
          tenant_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "security_audit_events_permission_key_fkey";
            columns: ["permission_key"];
            isOneToOne: false;
            referencedRelation: "permission_catalog";
            referencedColumns: ["permission_key"];
          },
        ];
      };
      tenant_role_permissions: {
        Row: {
          allowed: boolean;
          permission_key: string;
          role_key: Database["public"]["Enums"]["role_key"];
          tenant_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          allowed: boolean;
          permission_key: string;
          role_key: Database["public"]["Enums"]["role_key"];
          tenant_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          allowed?: boolean;
          permission_key?: string;
          role_key?: Database["public"]["Enums"]["role_key"];
          tenant_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "tenant_role_permissions_permission_key_fkey";
            columns: ["permission_key"];
            isOneToOne: false;
            referencedRelation: "permission_catalog";
            referencedColumns: ["permission_key"];
          },
        ];
      };
      workspace_request_command_idempotency: {
        Row: {
          actor_key: string;
          command_type: string;
          created_at: string;
          idempotency_key: string;
          request_fingerprint: string;
          result_id: string;
        };
        Insert: {
          actor_key: string;
          command_type: string;
          created_at?: string;
          idempotency_key: string;
          request_fingerprint: string;
          result_id: string;
        };
        Update: {
          actor_key?: string;
          command_type?: string;
          created_at?: string;
          idempotency_key?: string;
          request_fingerprint?: string;
          result_id?: string;
        };
        Relationships: [];
      };
      workspace_request_delegations: {
        Row: {
          created_at: string;
          created_by_user_id: string;
          delegate_user_id: string;
          expires_at: string;
          id: string;
          revoked_at: string | null;
          revoked_by_user_id: string | null;
          tenant_id: string;
        };
        Insert: {
          created_at?: string;
          created_by_user_id: string;
          delegate_user_id: string;
          expires_at: string;
          id?: string;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          tenant_id: string;
        };
        Update: {
          created_at?: string;
          created_by_user_id?: string;
          delegate_user_id?: string;
          expires_at?: string;
          id?: string;
          revoked_at?: string | null;
          revoked_by_user_id?: string | null;
          tenant_id?: string;
        };
        Relationships: [];
      };
      workspace_request_entry_tokens: {
        Row: {
          created_at: string;
          created_by_user_id: string;
          expires_at: string;
          id: string;
          revoked_at: string | null;
          tenant_id: string;
          token_digest: string;
        };
        Insert: {
          created_at?: string;
          created_by_user_id: string;
          expires_at: string;
          id?: string;
          revoked_at?: string | null;
          tenant_id: string;
          token_digest: string;
        };
        Update: {
          created_at?: string;
          created_by_user_id?: string;
          expires_at?: string;
          id?: string;
          revoked_at?: string | null;
          tenant_id?: string;
          token_digest?: string;
        };
        Relationships: [];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      account_status_request_fingerprint: {
        Args: {
          p_new_status: Database["public"]["Enums"]["account_status"];
          p_reason: string;
          p_target_user_id: string;
        };
        Returns: string;
      };
      authorize: {
        Args: {
          p_action_key?: string;
          p_actor_user_id: string;
          p_amount?: number;
          p_permission_key: string;
          p_resource_owner_user_id?: string;
          p_session_id: string;
          p_target_membership_id?: string;
          p_target_office_id?: string;
          p_target_tenant_id: string;
          p_target_user_id?: string;
          p_target_wallet_id?: string;
        };
        Returns: Database["authz"]["CompositeTypes"]["authorization_decision"];
        SetofOptions: {
          from: "*";
          to: "authorization_decision";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      authorize_financial_evidence_review: {
        Args: {
          p_action_key: string;
          p_actor_user_id: string;
          p_session_id: string;
          p_target_membership_id: string;
          p_target_office_id: string;
          p_target_tenant_id: string;
          p_target_user_id: string;
          p_target_wallet_id: string;
        };
        Returns: Database["authz"]["CompositeTypes"]["authorization_decision"];
        SetofOptions: {
          from: "*";
          to: "authorization_decision";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      authorize_without_commercial_restriction: {
        Args: {
          p_action_key?: string;
          p_actor_user_id: string;
          p_amount?: number;
          p_permission_key: string;
          p_resource_owner_user_id?: string;
          p_session_id: string;
          p_target_membership_id?: string;
          p_target_office_id?: string;
          p_target_tenant_id: string;
          p_target_user_id?: string;
          p_target_wallet_id?: string;
        };
        Returns: Database["authz"]["CompositeTypes"]["authorization_decision"];
        SetofOptions: {
          from: "*";
          to: "authorization_decision";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      can_read_membership: {
        Args: { p_membership_id: string };
        Returns: boolean;
      };
      can_read_office: { Args: { p_office_id: string }; Returns: boolean };
      can_read_wallet: { Args: { p_wallet_id: string }; Returns: boolean };
      configure_financial_evidence_reviewer: {
        Args: {
          p_actor_user_id: string;
          p_enabled: boolean;
          p_reviewer_membership_id: string;
          p_session_id?: string;
          p_tenant_id: string;
        };
        Returns: string;
      };
      consume_action_confirmation: {
        Args: {
          p_action_key: string;
          p_session_id: string;
          p_target_id: string;
          p_target_type: string;
          p_user_id: string;
        };
        Returns: boolean;
      };
      establish_step_up: { Args: never; Returns: Json };
      is_active_account: { Args: never; Returns: boolean };
      is_active_member_in_tenant: {
        Args: { p_tenant_id: string };
        Returns: boolean;
      };
      is_elevated_session_valid: {
        Args: { p_session_id: string; p_user_id: string };
        Returns: boolean;
      };
      is_platform_admin: { Args: { p_user_id: string }; Returns: boolean };
      seed_default_role_policy: {
        Args: { p_tenant_id: string };
        Returns: undefined;
      };
      seed_tenant_role_permissions: {
        Args: { p_tenant_id: string };
        Returns: undefined;
      };
      set_account_status: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_new_status: Database["public"]["Enums"]["account_status"];
          p_reason: string;
          p_session_id: string;
          p_target_user_id: string;
        };
        Returns: Database["public"]["Tables"]["user_accounts"]["Row"];
        SetofOptions: {
          from: "*";
          to: "user_accounts";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      workspace_request_actor: {
        Args: {
          p_membership_id: string;
          p_require_ptm?: boolean;
          p_user_id: string;
        };
        Returns: Database["public"]["Tables"]["memberships"]["Row"];
        SetofOptions: {
          from: "*";
          to: "memberships";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
    };
    Enums: {
      access_effect: "allow" | "deny";
      access_scope_type: "tenant" | "office_subtree" | "member";
      authorization_decision_state: "ALLOW" | "DENY" | "STEP_UP_REQUIRED";
      authorization_source:
        | "protected_baseline"
        | "role_policy"
        | "explicit_grant"
        | "explicit_deny"
        | "system_rule"
        | "default_deny";
      required_auth_level: "none" | "elevated" | "elevated_and_confirmed";
    };
    CompositeTypes: {
      authorization_decision: {
        decision:
          | Database["authz"]["Enums"]["authorization_decision_state"]
          | null;
        permission_key: string | null;
        actor_user_id: string | null;
        target_tenant_id: string | null;
        target_office_id: string | null;
        target_membership_id: string | null;
        target_user_id: string | null;
        target_wallet_id: string | null;
        source: Database["authz"]["Enums"]["authorization_source"] | null;
        source_id: string | null;
        reason_code: string | null;
        required_auth_level:
          | Database["authz"]["Enums"]["required_auth_level"]
          | null;
        max_auth_age_seconds: number | null;
      };
    };
  };
  commercial: {
    Tables: {
      billing_owner_assignments: {
        Row: {
          assigned_by_user_id: string;
          assignment_reason: string;
          end_reason: string | null;
          ended_at: string | null;
          ended_by_user_id: string | null;
          id: string;
          membership_id: string;
          owner_user_id: string;
          started_at: string;
          tenant_id: string;
        };
        Insert: {
          assigned_by_user_id: string;
          assignment_reason: string;
          end_reason?: string | null;
          ended_at?: string | null;
          ended_by_user_id?: string | null;
          id?: string;
          membership_id: string;
          owner_user_id: string;
          started_at?: string;
          tenant_id: string;
        };
        Update: {
          assigned_by_user_id?: string;
          assignment_reason?: string;
          end_reason?: string | null;
          ended_at?: string | null;
          ended_by_user_id?: string | null;
          id?: string;
          membership_id?: string;
          owner_user_id?: string;
          started_at?: string;
          tenant_id?: string;
        };
        Relationships: [];
      };
      extra_catalog: {
        Row: {
          created_at: string;
          display_name: string;
          extra_key: string;
        };
        Insert: {
          created_at?: string;
          display_name: string;
          extra_key: string;
        };
        Update: {
          created_at?: string;
          display_name?: string;
          extra_key?: string;
        };
        Relationships: [];
      };
      plan_versions: {
        Row: {
          billing_cadence_code: string | null;
          created_at: string;
          currency_code: string;
          effective_from: string;
          effective_until: string | null;
          id: string;
          list_price_amount: number;
          maximum_covered_users: number | null;
          minimum_covered_users: number;
          plan_id: string;
          version_number: number;
        };
        Insert: {
          billing_cadence_code?: string | null;
          created_at?: string;
          currency_code: string;
          effective_from: string;
          effective_until?: string | null;
          id?: string;
          list_price_amount: number;
          maximum_covered_users?: number | null;
          minimum_covered_users: number;
          plan_id: string;
          version_number: number;
        };
        Update: {
          billing_cadence_code?: string | null;
          created_at?: string;
          currency_code?: string;
          effective_from?: string;
          effective_until?: string | null;
          id?: string;
          list_price_amount?: number;
          maximum_covered_users?: number | null;
          minimum_covered_users?: number;
          plan_id?: string;
          version_number?: number;
        };
        Relationships: [
          {
            foreignKeyName: "plan_versions_plan_id_fkey";
            columns: ["plan_id"];
            isOneToOne: false;
            referencedRelation: "plans";
            referencedColumns: ["id"];
          },
        ];
      };
      plans: {
        Row: {
          created_at: string;
          display_name: string;
          id: string;
          plan_key: string;
        };
        Insert: {
          created_at?: string;
          display_name: string;
          id?: string;
          plan_key: string;
        };
        Update: {
          created_at?: string;
          display_name?: string;
          id?: string;
          plan_key?: string;
        };
        Relationships: [];
      };
      subscription_status_events: {
        Row: {
          actor_user_id: string | null;
          id: number;
          new_status: Database["commercial"]["Enums"]["subscription_status"];
          occurred_at: string;
          previous_status:
            | Database["commercial"]["Enums"]["subscription_status"]
            | null;
          reason: string;
          subscription_id: string;
          tenant_id: string;
        };
        Insert: {
          actor_user_id?: string | null;
          id?: never;
          new_status: Database["commercial"]["Enums"]["subscription_status"];
          occurred_at?: string;
          previous_status?:
            | Database["commercial"]["Enums"]["subscription_status"]
            | null;
          reason: string;
          subscription_id: string;
          tenant_id: string;
        };
        Update: {
          actor_user_id?: string | null;
          id?: never;
          new_status?: Database["commercial"]["Enums"]["subscription_status"];
          occurred_at?: string;
          previous_status?:
            | Database["commercial"]["Enums"]["subscription_status"]
            | null;
          reason?: string;
          subscription_id?: string;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "subscription_status_events_tenant_id_subscription_id_fkey";
            columns: ["tenant_id", "subscription_id"];
            isOneToOne: false;
            referencedRelation: "tenant_subscriptions";
            referencedColumns: ["tenant_id", "id"];
          },
        ];
      };
      tenant_extra_entitlements: {
        Row: {
          created_at: string;
          ends_at: string | null;
          extra_key: string;
          grant_reason: string;
          granted_by_user_id: string | null;
          id: string;
          starts_at: string;
          tenant_id: string;
        };
        Insert: {
          created_at?: string;
          ends_at?: string | null;
          extra_key: string;
          grant_reason: string;
          granted_by_user_id?: string | null;
          id?: string;
          starts_at: string;
          tenant_id: string;
        };
        Update: {
          created_at?: string;
          ends_at?: string | null;
          extra_key?: string;
          grant_reason?: string;
          granted_by_user_id?: string | null;
          id?: string;
          starts_at?: string;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "tenant_extra_entitlements_extra_key_fkey";
            columns: ["extra_key"];
            isOneToOne: false;
            referencedRelation: "extra_catalog";
            referencedColumns: ["extra_key"];
          },
        ];
      };
      tenant_subscriptions: {
        Row: {
          created_at: string;
          created_by_user_id: string | null;
          id: string;
          is_current: boolean;
          plan_version_id: string;
          service_ends_at: string | null;
          starts_at: string;
          status: Database["commercial"]["Enums"]["subscription_status"];
          status_changed_at: string;
          status_changed_by_user_id: string | null;
          status_reason: string;
          superseded_at: string | null;
          tenant_id: string;
        };
        Insert: {
          created_at?: string;
          created_by_user_id?: string | null;
          id?: string;
          is_current?: boolean;
          plan_version_id: string;
          service_ends_at?: string | null;
          starts_at: string;
          status: Database["commercial"]["Enums"]["subscription_status"];
          status_changed_at?: string;
          status_changed_by_user_id?: string | null;
          status_reason: string;
          superseded_at?: string | null;
          tenant_id: string;
        };
        Update: {
          created_at?: string;
          created_by_user_id?: string | null;
          id?: string;
          is_current?: boolean;
          plan_version_id?: string;
          service_ends_at?: string | null;
          starts_at?: string;
          status?: Database["commercial"]["Enums"]["subscription_status"];
          status_changed_at?: string;
          status_changed_by_user_id?: string | null;
          status_reason?: string;
          superseded_at?: string | null;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "tenant_subscriptions_plan_version_id_fkey";
            columns: ["plan_version_id"];
            isOneToOne: false;
            referencedRelation: "plan_versions";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      assert_seat_capacity: {
        Args: {
          p_at?: string;
          p_candidate_user_id: string;
          p_tenant_id: string;
        };
        Returns:
          Database["commercial"]["CompositeTypes"]["seat_capacity_decision"];
        SetofOptions: {
          from: "*";
          to: "seat_capacity_decision";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      count_billable_users: { Args: { p_tenant_id: string }; Returns: number };
      evaluate_seat_capacity: {
        Args: {
          p_at?: string;
          p_candidate_user_id: string;
          p_tenant_id: string;
        };
        Returns:
          Database["commercial"]["CompositeTypes"]["seat_capacity_decision"];
        SetofOptions: {
          from: "*";
          to: "seat_capacity_decision";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      has_active_extra: {
        Args: { p_at?: string; p_extra_key: string; p_tenant_id: string };
        Returns: boolean;
      };
      is_tenant_commercially_restricted: {
        Args: { p_at?: string; p_tenant_id: string };
        Returns: boolean;
      };
      set_billing_owner: {
        Args: {
          p_actor_user_id: string;
          p_membership_id: string;
          p_reason: string;
          p_session_id: string;
          p_tenant_id: string;
        };
        Returns: string;
      };
    };
    Enums: {
      subscription_status:
        | "active"
        | "payment_due"
        | "grace_period"
        | "past_due"
        | "suspended"
        | "cancelled";
    };
    CompositeTypes: {
      seat_capacity_decision: {
        allowed: boolean | null;
        tenant_id: string | null;
        candidate_user_id: string | null;
        current_billable_users: number | null;
        projected_billable_users: number | null;
        capacity_limit: number | null;
        reason_code: string | null;
      };
    };
  };
  evidence: {
    Tables: {
      financial_evidence: {
        Row: {
          evidence_type: string;
          file_size_bytes: number;
          id: string;
          mime_type: string;
          notes: string | null;
          observed_at: string | null;
          original_filename: string;
          provider: string | null;
          provider_reference: string | null;
          sha256: string;
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_at: string;
          submitted_by_user_id: string;
          supersedes_evidence_id: string | null;
          tenant_id: string;
        };
        Insert: {
          evidence_type: string;
          file_size_bytes: number;
          id?: string;
          mime_type: string;
          notes?: string | null;
          observed_at?: string | null;
          original_filename: string;
          provider?: string | null;
          provider_reference?: string | null;
          sha256: string;
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_at?: string;
          submitted_by_user_id: string;
          supersedes_evidence_id?: string | null;
          tenant_id: string;
        };
        Update: {
          evidence_type?: string;
          file_size_bytes?: number;
          id?: string;
          mime_type?: string;
          notes?: string | null;
          observed_at?: string | null;
          original_filename?: string;
          provider?: string | null;
          provider_reference?: string | null;
          sha256?: string;
          storage_bucket_id?: string;
          storage_object_path?: string;
          submitted_at?: string;
          submitted_by_user_id?: string;
          supersedes_evidence_id?: string | null;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "financial_evidence_supersedes_evidence_id_fkey";
            columns: ["supersedes_evidence_id"];
            isOneToOne: false;
            referencedRelation: "financial_evidence";
            referencedColumns: ["id"];
          },
        ];
      };
      financial_operation_evidence: {
        Row: {
          administrative_adjustment_revision_id: string | null;
          currency_conversion_revision_id: string | null;
          evidence_id: string;
          income_record_id: string | null;
          linked_at: string;
          returned_fund_revision_id: string | null;
        };
        Insert: {
          administrative_adjustment_revision_id?: string | null;
          currency_conversion_revision_id?: string | null;
          evidence_id: string;
          income_record_id?: string | null;
          linked_at?: string;
          returned_fund_revision_id?: string | null;
        };
        Update: {
          administrative_adjustment_revision_id?: string | null;
          currency_conversion_revision_id?: string | null;
          evidence_id?: string;
          income_record_id?: string | null;
          linked_at?: string;
          returned_fund_revision_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "financial_operation_evidence_evidence_id_fkey";
            columns: ["evidence_id"];
            isOneToOne: true;
            referencedRelation: "financial_evidence";
            referencedColumns: ["id"];
          },
        ];
      };
      financial_operation_review_decisions: {
        Row: {
          administrative_adjustment_id: string | null;
          currency_conversion_id: string | null;
          decided_at: string;
          decision: Database["evidence"]["Enums"]["review_decision"];
          id: string;
          returned_fund_id: string | null;
          review_note: string;
          reviewer_assignment_id: string;
          reviewer_user_id: string;
        };
        Insert: {
          administrative_adjustment_id?: string | null;
          currency_conversion_id?: string | null;
          decided_at?: string;
          decision: Database["evidence"]["Enums"]["review_decision"];
          id?: string;
          returned_fund_id?: string | null;
          review_note: string;
          reviewer_assignment_id: string;
          reviewer_user_id: string;
        };
        Update: {
          administrative_adjustment_id?: string | null;
          currency_conversion_id?: string | null;
          decided_at?: string;
          decision?: Database["evidence"]["Enums"]["review_decision"];
          id?: string;
          returned_fund_id?: string | null;
          review_note?: string;
          reviewer_assignment_id?: string;
          reviewer_user_id?: string;
        };
        Relationships: [];
      };
      financial_operation_verification_attempts: {
        Row: {
          administrative_adjustment_revision_id: string | null;
          created_at: string;
          currency_conversion_revision_id: string | null;
          extracted_facts: Json;
          id: string;
          mismatch_reasons: Json;
          outcome: Database["evidence"]["Enums"]["verification_outcome"];
          request_fingerprint: string;
          returned_fund_revision_id: string | null;
          verification_request_id: string;
          verifier_name: string;
          verifier_version: string | null;
        };
        Insert: {
          administrative_adjustment_revision_id?: string | null;
          created_at?: string;
          currency_conversion_revision_id?: string | null;
          extracted_facts: Json;
          id?: string;
          mismatch_reasons: Json;
          outcome: Database["evidence"]["Enums"]["verification_outcome"];
          request_fingerprint: string;
          returned_fund_revision_id?: string | null;
          verification_request_id: string;
          verifier_name: string;
          verifier_version?: string | null;
        };
        Update: {
          administrative_adjustment_revision_id?: string | null;
          created_at?: string;
          currency_conversion_revision_id?: string | null;
          extracted_facts?: Json;
          id?: string;
          mismatch_reasons?: Json;
          outcome?: Database["evidence"]["Enums"]["verification_outcome"];
          request_fingerprint?: string;
          returned_fund_revision_id?: string | null;
          verification_request_id?: string;
          verifier_name?: string;
          verifier_version?: string | null;
        };
        Relationships: [];
      };
      financial_upload_intents: {
        Row: {
          created_at: string;
          evidence_type: string;
          expires_at: string;
          file_size_bytes: number;
          finalized_at: string | null;
          finalized_evidence_id: string | null;
          id: string;
          idempotency_key: string;
          mime_type: string;
          original_filename: string;
          sha256: string;
          status: Database["evidence"]["Enums"]["upload_intent_status"];
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_by_user_id: string;
          target_id: string;
          target_type: string;
          tenant_id: string;
        };
        Insert: {
          created_at?: string;
          evidence_type: string;
          expires_at: string;
          file_size_bytes: number;
          finalized_at?: string | null;
          finalized_evidence_id?: string | null;
          id?: string;
          idempotency_key: string;
          mime_type: string;
          original_filename: string;
          sha256: string;
          status?: Database["evidence"]["Enums"]["upload_intent_status"];
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_by_user_id: string;
          target_id: string;
          target_type: string;
          tenant_id: string;
        };
        Update: {
          created_at?: string;
          evidence_type?: string;
          expires_at?: string;
          file_size_bytes?: number;
          finalized_at?: string | null;
          finalized_evidence_id?: string | null;
          id?: string;
          idempotency_key?: string;
          mime_type?: string;
          original_filename?: string;
          sha256?: string;
          status?: Database["evidence"]["Enums"]["upload_intent_status"];
          storage_bucket_id?: string;
          storage_object_path?: string;
          submitted_by_user_id?: string;
          target_id?: string;
          target_type?: string;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "financial_upload_intents_finalized_evidence_id_fkey";
            columns: ["finalized_evidence_id"];
            isOneToOne: false;
            referencedRelation: "financial_evidence";
            referencedColumns: ["id"];
          },
        ];
      };
      income_upload_intents: {
        Row: {
          actor_user_id: string;
          cancelled_at: string | null;
          created_at: string;
          currency_code: string;
          expires_at: string;
          file_size_bytes: number;
          gross_amount: number;
          id: string;
          income_record_id: string | null;
          mime_type: string;
          observed_at: string;
          original_filename: string;
          provider_reference: string;
          sha256_hex: string;
          storage_object_path: string;
          target_membership_id: string;
        };
        Insert: {
          actor_user_id: string;
          cancelled_at?: string | null;
          created_at?: string;
          currency_code: string;
          expires_at?: string;
          file_size_bytes: number;
          gross_amount: number;
          id: string;
          income_record_id?: string | null;
          mime_type: string;
          observed_at: string;
          original_filename: string;
          provider_reference?: string;
          sha256_hex: string;
          storage_object_path: string;
          target_membership_id: string;
        };
        Update: {
          actor_user_id?: string;
          cancelled_at?: string | null;
          created_at?: string;
          currency_code?: string;
          expires_at?: string;
          file_size_bytes?: number;
          gross_amount?: number;
          id?: string;
          income_record_id?: string | null;
          mime_type?: string;
          observed_at?: string;
          original_filename?: string;
          provider_reference?: string;
          sha256_hex?: string;
          storage_object_path?: string;
          target_membership_id?: string;
        };
        Relationships: [];
      };
      payout_upload_files: {
        Row: {
          file_size_bytes: number;
          id: string;
          mime_type: string;
          ordinal: number;
          original_filename: string;
          sha256_hex: string;
          stage_id: string;
          storage_object_path: string;
        };
        Insert: {
          file_size_bytes: number;
          id?: string;
          mime_type: string;
          ordinal: number;
          original_filename: string;
          sha256_hex: string;
          stage_id: string;
          storage_object_path: string;
        };
        Update: {
          file_size_bytes?: number;
          id?: string;
          mime_type?: string;
          ordinal?: number;
          original_filename?: string;
          sha256_hex?: string;
          stage_id?: string;
          storage_object_path?: string;
        };
        Relationships: [
          {
            foreignKeyName: "payout_upload_files_stage_id_fkey";
            columns: ["stage_id"];
            isOneToOne: false;
            referencedRelation: "payout_upload_stages";
            referencedColumns: ["id"];
          },
        ];
      };
      payout_upload_stages: {
        Row: {
          actor_user_id: string;
          created_at: string;
          descriptors: Json;
          expires_at: string;
          facts: Json;
          id: string;
          operation: string;
          payout_assertion_id: string | null;
          result_assertion_id: string | null;
          withdrawal_id: string;
        };
        Insert: {
          actor_user_id: string;
          created_at?: string;
          descriptors: Json;
          expires_at?: string;
          facts: Json;
          id: string;
          operation: string;
          payout_assertion_id?: string | null;
          result_assertion_id?: string | null;
          withdrawal_id: string;
        };
        Update: {
          actor_user_id?: string;
          created_at?: string;
          descriptors?: Json;
          expires_at?: string;
          facts?: Json;
          id?: string;
          operation?: string;
          payout_assertion_id?: string | null;
          result_assertion_id?: string | null;
          withdrawal_id?: string;
        };
        Relationships: [];
      };
      review_decisions: {
        Row: {
          decided_at: string;
          decision: Database["evidence"]["Enums"]["review_decision"];
          id: string;
          payout_assertion_id: string;
          review_note: string;
          reviewer_assignment_id: string;
          reviewer_user_id: string;
        };
        Insert: {
          decided_at?: string;
          decision: Database["evidence"]["Enums"]["review_decision"];
          id?: string;
          payout_assertion_id: string;
          review_note: string;
          reviewer_assignment_id: string;
          reviewer_user_id: string;
        };
        Update: {
          decided_at?: string;
          decision?: Database["evidence"]["Enums"]["review_decision"];
          id?: string;
          payout_assertion_id?: string;
          review_note?: string;
          reviewer_assignment_id?: string;
          reviewer_user_id?: string;
        };
        Relationships: [];
      };
      verification_attempts: {
        Row: {
          created_at: string;
          extracted_facts: Json;
          id: string;
          mismatch_reasons: Json;
          outcome: Database["evidence"]["Enums"]["verification_outcome"];
          payout_assertion_revision_id: string;
          request_fingerprint: string;
          verification_request_id: string;
          verifier_name: string;
          verifier_version: string | null;
        };
        Insert: {
          created_at?: string;
          extracted_facts: Json;
          id?: string;
          mismatch_reasons: Json;
          outcome: Database["evidence"]["Enums"]["verification_outcome"];
          payout_assertion_revision_id: string;
          request_fingerprint: string;
          verification_request_id: string;
          verifier_name: string;
          verifier_version?: string | null;
        };
        Update: {
          created_at?: string;
          extracted_facts?: Json;
          id?: string;
          mismatch_reasons?: Json;
          outcome?: Database["evidence"]["Enums"]["verification_outcome"];
          payout_assertion_revision_id?: string;
          request_fingerprint?: string;
          verification_request_id?: string;
          verifier_name?: string;
          verifier_version?: string | null;
        };
        Relationships: [];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      attach_financial_operation_evidence: {
        Args: {
          p_evidence_items: Json;
          p_evidence_type: string;
          p_submitted_by_user_id: string;
          p_target_id: string;
          p_target_type: string;
          p_tenant_id: string;
        };
        Returns: number;
      };
      attach_payout_evidence: {
        Args: {
          p_evidence_items: Json;
          p_payout_assertion_revision_id: string;
          p_submitted_by_user_id: string;
          p_tenant_id: string;
        };
        Returns: number;
      };
      authorize_income_target: {
        Args: {
          p_actor_user_id: string;
          p_amount: number;
          p_income_id?: string;
          p_membership_id: string;
          p_session_id: string;
        };
        Returns: Database["public"]["Tables"]["memberships"]["Row"];
        SetofOptions: {
          from: "*";
          to: "memberships";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      authorize_payout_stage: {
        Args: {
          p_actor: string;
          p_allow_expired?: boolean;
          p_session: string;
          p_stage:
            Database["evidence"]["Tables"]["payout_upload_stages"]["Row"];
        };
        Returns: undefined;
      };
      finalize_financial_evidence_upload: {
        Args: {
          p_actor_user_id: string;
          p_intent_id: string;
          p_notes?: string;
          p_observed_at: string;
          p_provider?: string;
          p_provider_reference?: string;
          p_verified_file_size_bytes: number;
          p_verified_sha256_hex: string;
        };
        Returns: {
          evidence_type: string;
          file_size_bytes: number;
          id: string;
          mime_type: string;
          notes: string | null;
          observed_at: string | null;
          original_filename: string;
          provider: string | null;
          provider_reference: string | null;
          sha256: string;
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_at: string;
          submitted_by_user_id: string;
          supersedes_evidence_id: string | null;
          tenant_id: string;
        };
        SetofOptions: {
          from: "*";
          to: "financial_evidence";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      financial_upload_request_fingerprint: {
        Args: {
          p_evidence_type: string;
          p_file_size_bytes: number;
          p_mime_type: string;
          p_original_filename: string;
          p_sha256_hex: string;
          p_target_id: string;
          p_target_type: string;
        };
        Returns: string;
      };
      payout_verification_snapshot: {
        Args: { p_stage_id: string };
        Returns: Json;
      };
      request_financial_evidence_upload: {
        Args: {
          p_actor_user_id: string;
          p_evidence_type: string;
          p_file_size_bytes: number;
          p_idempotency_key: string;
          p_mime_type: string;
          p_original_filename: string;
          p_sha256_hex: string;
          p_target_id: string;
          p_target_type: string;
        };
        Returns: {
          created_at: string;
          evidence_type: string;
          expires_at: string;
          file_size_bytes: number;
          finalized_at: string | null;
          finalized_evidence_id: string | null;
          id: string;
          idempotency_key: string;
          mime_type: string;
          original_filename: string;
          sha256: string;
          status: Database["evidence"]["Enums"]["upload_intent_status"];
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_by_user_id: string;
          target_id: string;
          target_type: string;
          tenant_id: string;
        };
        SetofOptions: {
          from: "*";
          to: "financial_upload_intents";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      resolve_financial_operation_target: {
        Args: { p_target_id: string; p_target_type: string };
        Returns: {
          submitter_user_id: string;
          tenant_id: string;
        }[];
      };
    };
    Enums: {
      review_decision: "clear" | "reject";
      upload_intent_status: "pending" | "finalized" | "expired" | "cancelled";
      verification_outcome: "match" | "mismatch";
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
  financial_ops: {
    Tables: {
      administrative_adjustment_lines: {
        Row: {
          administrative_adjustment_id: string;
          allocation_basis_points: number;
          amount: number;
          ledger_account_id: string;
          pocket_key: string;
          remainder_rank: number;
        };
        Insert: {
          administrative_adjustment_id: string;
          allocation_basis_points: number;
          amount: number;
          ledger_account_id: string;
          pocket_key: string;
          remainder_rank: number;
        };
        Update: {
          administrative_adjustment_id?: string;
          allocation_basis_points?: number;
          amount?: number;
          ledger_account_id?: string;
          pocket_key?: string;
          remainder_rank?: number;
        };
        Relationships: [
          {
            foreignKeyName:
              "administrative_adjustment_lin_administrative_adjustment_id_fkey";
            columns: ["administrative_adjustment_id"];
            isOneToOne: false;
            referencedRelation: "administrative_adjustments";
            referencedColumns: ["id"];
          },
        ];
      };
      administrative_adjustment_revisions: {
        Row: {
          administrative_adjustment_id: string;
          correction_idempotency_key: string | null;
          created_at: string;
          id: string;
          revision_number: number;
          submitted_by_user_id: string;
        };
        Insert: {
          administrative_adjustment_id: string;
          correction_idempotency_key?: string | null;
          created_at?: string;
          id?: string;
          revision_number: number;
          submitted_by_user_id: string;
        };
        Update: {
          administrative_adjustment_id?: string;
          correction_idempotency_key?: string | null;
          created_at?: string;
          id?: string;
          revision_number?: number;
          submitted_by_user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "administrative_adjustment_rev_administrative_adjustment_id_fkey";
            columns: ["administrative_adjustment_id"];
            isOneToOne: false;
            referencedRelation: "administrative_adjustments";
            referencedColumns: ["id"];
          },
        ];
      };
      administrative_adjustments: {
        Row: {
          accepted_at: string | null;
          accepted_via:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          allocation_policy_version_id: string;
          amount: number;
          currency_code: string;
          current_revision_number: number;
          direction: Database["financial_ops"]["Enums"]["adjustment_direction"];
          evidence_required: boolean;
          id: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference: string;
          owner_user_id: string;
          posted_financial_transaction_id: string | null;
          reason: string;
          request_fingerprint: string;
          status:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at: string;
          submitted_by_user_id: string;
          tenant_id: string;
          updated_at: string;
          version: number;
          wallet_id: string;
        };
        Insert: {
          accepted_at?: string | null;
          accepted_via?:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          allocation_policy_version_id: string;
          amount: number;
          currency_code: string;
          current_revision_number?: number;
          direction: Database["financial_ops"]["Enums"]["adjustment_direction"];
          evidence_required: boolean;
          id?: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference?: string;
          owner_user_id: string;
          posted_financial_transaction_id?: string | null;
          reason: string;
          request_fingerprint: string;
          status?:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at?: string;
          submitted_by_user_id: string;
          tenant_id: string;
          updated_at?: string;
          version?: number;
          wallet_id: string;
        };
        Update: {
          accepted_at?: string | null;
          accepted_via?:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          allocation_policy_version_id?: string;
          amount?: number;
          currency_code?: string;
          current_revision_number?: number;
          direction?:
            Database["financial_ops"]["Enums"]["adjustment_direction"];
          evidence_required?: boolean;
          id?: string;
          idempotency_key?: string;
          membership_id?: string;
          office_id?: string;
          operation_reference?: string;
          owner_user_id?: string;
          posted_financial_transaction_id?: string | null;
          reason?: string;
          request_fingerprint?: string;
          status?:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at?: string;
          submitted_by_user_id?: string;
          tenant_id?: string;
          updated_at?: string;
          version?: number;
          wallet_id?: string;
        };
        Relationships: [];
      };
      bank_resolution_intents: {
        Row: {
          account_holder_name: string | null;
          account_number: string;
          actor_user_id: string;
          bank_code: string;
          confirmation_key: string | null;
          created_at: string;
          existing_payout_account_id: string | null;
          expires_at: string;
          id: string;
          institution_name: string | null;
          membership_id: string;
          resolved_at: string | null;
          result_payout_account_id: string | null;
          wallet_id: string;
        };
        Insert: {
          account_holder_name?: string | null;
          account_number: string;
          actor_user_id: string;
          bank_code: string;
          confirmation_key?: string | null;
          created_at?: string;
          existing_payout_account_id?: string | null;
          expires_at?: string;
          id: string;
          institution_name?: string | null;
          membership_id: string;
          resolved_at?: string | null;
          result_payout_account_id?: string | null;
          wallet_id: string;
        };
        Update: {
          account_holder_name?: string | null;
          account_number?: string;
          actor_user_id?: string;
          bank_code?: string;
          confirmation_key?: string | null;
          created_at?: string;
          existing_payout_account_id?: string | null;
          expires_at?: string;
          id?: string;
          institution_name?: string | null;
          membership_id?: string;
          resolved_at?: string | null;
          result_payout_account_id?: string | null;
          wallet_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "bank_resolution_intents_existing_payout_account_id_fkey";
            columns: ["existing_payout_account_id"];
            isOneToOne: false;
            referencedRelation: "payout_accounts";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName:
              "bank_resolution_intents_result_payout_account_id_fkey";
            columns: ["result_payout_account_id"];
            isOneToOne: false;
            referencedRelation: "payout_accounts";
            referencedColumns: ["id"];
          },
        ];
      };
      currency_conversion_revisions: {
        Row: {
          converted_at: string;
          correction_idempotency_key: string | null;
          created_at: string;
          currency_conversion_id: string;
          destination_amount: number;
          destination_currency_code: string;
          effective_rate: number;
          id: string;
          notes: string | null;
          provider: string;
          provider_fee_amount: number;
          provider_fee_currency: string | null;
          provider_rate: number | null;
          provider_reference: string | null;
          revision_number: number;
          source_amount: number;
          source_currency_code: string;
          submitted_by_user_id: string;
        };
        Insert: {
          converted_at: string;
          correction_idempotency_key?: string | null;
          created_at?: string;
          currency_conversion_id: string;
          destination_amount: number;
          destination_currency_code: string;
          effective_rate: number;
          id?: string;
          notes?: string | null;
          provider: string;
          provider_fee_amount?: number;
          provider_fee_currency?: string | null;
          provider_rate?: number | null;
          provider_reference?: string | null;
          revision_number: number;
          source_amount: number;
          source_currency_code: string;
          submitted_by_user_id: string;
        };
        Update: {
          converted_at?: string;
          correction_idempotency_key?: string | null;
          created_at?: string;
          currency_conversion_id?: string;
          destination_amount?: number;
          destination_currency_code?: string;
          effective_rate?: number;
          id?: string;
          notes?: string | null;
          provider?: string;
          provider_fee_amount?: number;
          provider_fee_currency?: string | null;
          provider_rate?: number | null;
          provider_reference?: string | null;
          revision_number?: number;
          source_amount?: number;
          source_currency_code?: string;
          submitted_by_user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "currency_conversion_revisions_currency_conversion_id_fkey";
            columns: ["currency_conversion_id"];
            isOneToOne: false;
            referencedRelation: "currency_conversions";
            referencedColumns: ["id"];
          },
        ];
      };
      currency_conversions: {
        Row: {
          accepted_at: string | null;
          accepted_via:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          current_revision_number: number;
          destination_ledger_account_id: string;
          id: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference: string;
          owner_user_id: string;
          posted_financial_transaction_id: string | null;
          request_fingerprint: string;
          source_ledger_account_id: string;
          status:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at: string;
          submitted_by_user_id: string;
          tenant_id: string;
          updated_at: string;
          version: number;
          wallet_id: string;
          withdrawal_id: string | null;
        };
        Insert: {
          accepted_at?: string | null;
          accepted_via?:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          current_revision_number?: number;
          destination_ledger_account_id: string;
          id?: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference?: string;
          owner_user_id: string;
          posted_financial_transaction_id?: string | null;
          request_fingerprint: string;
          source_ledger_account_id: string;
          status?:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at?: string;
          submitted_by_user_id: string;
          tenant_id: string;
          updated_at?: string;
          version?: number;
          wallet_id: string;
          withdrawal_id?: string | null;
        };
        Update: {
          accepted_at?: string | null;
          accepted_via?:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          current_revision_number?: number;
          destination_ledger_account_id?: string;
          id?: string;
          idempotency_key?: string;
          membership_id?: string;
          office_id?: string;
          operation_reference?: string;
          owner_user_id?: string;
          posted_financial_transaction_id?: string | null;
          request_fingerprint?: string;
          source_ledger_account_id?: string;
          status?:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at?: string;
          submitted_by_user_id?: string;
          tenant_id?: string;
          updated_at?: string;
          version?: number;
          wallet_id?: string;
          withdrawal_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "currency_conversions_withdrawal_id_fkey";
            columns: ["withdrawal_id"];
            isOneToOne: false;
            referencedRelation: "withdrawal_requests";
            referencedColumns: ["id"];
          },
        ];
      };
      financial_reversals: {
        Row: {
          id: string;
          idempotency_key: string;
          operation_reference: string;
          original_financial_transaction_id: string;
          reason: string;
          reinstates_reversal_id: string | null;
          request_fingerprint: string;
          reversal_financial_transaction_id: string;
          reversed_at: string;
          reversed_by_user_id: string;
          tenant_id: string;
        };
        Insert: {
          id?: string;
          idempotency_key: string;
          operation_reference?: string;
          original_financial_transaction_id: string;
          reason: string;
          reinstates_reversal_id?: string | null;
          request_fingerprint: string;
          reversal_financial_transaction_id: string;
          reversed_at?: string;
          reversed_by_user_id: string;
          tenant_id: string;
        };
        Update: {
          id?: string;
          idempotency_key?: string;
          operation_reference?: string;
          original_financial_transaction_id?: string;
          reason?: string;
          reinstates_reversal_id?: string | null;
          request_fingerprint?: string;
          reversal_financial_transaction_id?: string;
          reversed_at?: string;
          reversed_by_user_id?: string;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "financial_reversals_reinstates_reversal_id_fkey";
            columns: ["reinstates_reversal_id"];
            isOneToOne: false;
            referencedRelation: "financial_reversals";
            referencedColumns: ["id"];
          },
        ];
      };
      funding_reservations: {
        Row: {
          amount: number;
          consumed_at: string | null;
          created_at: string;
          id: string;
          ledger_account_id: string;
          release_reason: string | null;
          released_at: string | null;
          status: Database["financial_ops"]["Enums"]["reservation_status"];
          withdrawal_id: string;
        };
        Insert: {
          amount: number;
          consumed_at?: string | null;
          created_at?: string;
          id?: string;
          ledger_account_id: string;
          release_reason?: string | null;
          released_at?: string | null;
          status?: Database["financial_ops"]["Enums"]["reservation_status"];
          withdrawal_id: string;
        };
        Update: {
          amount?: number;
          consumed_at?: string | null;
          created_at?: string;
          id?: string;
          ledger_account_id?: string;
          release_reason?: string | null;
          released_at?: string | null;
          status?: Database["financial_ops"]["Enums"]["reservation_status"];
          withdrawal_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "funding_reservations_withdrawal_id_fkey";
            columns: ["withdrawal_id"];
            isOneToOne: true;
            referencedRelation: "withdrawal_requests";
            referencedColumns: ["id"];
          },
        ];
      };
      income_allocations: {
        Row: {
          allocated_amount: number;
          allocation_basis_points: number;
          income_record_id: string;
          ledger_account_id: string;
          pocket_key: string;
          remainder_rank: number;
        };
        Insert: {
          allocated_amount: number;
          allocation_basis_points: number;
          income_record_id: string;
          ledger_account_id: string;
          pocket_key: string;
          remainder_rank: number;
        };
        Update: {
          allocated_amount?: number;
          allocation_basis_points?: number;
          income_record_id?: string;
          ledger_account_id?: string;
          pocket_key?: string;
          remainder_rank?: number;
        };
        Relationships: [
          {
            foreignKeyName: "income_allocations_income_record_id_fkey";
            columns: ["income_record_id"];
            isOneToOne: false;
            referencedRelation: "income_records";
            referencedColumns: ["id"];
          },
        ];
      };
      income_records: {
        Row: {
          allocation_policy_version_id: string;
          currency_code: string;
          financial_transaction_id: string;
          gross_amount: number;
          id: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference: string;
          owner_user_id: string;
          recorded_at: string;
          recorded_by_user_id: string;
          request_fingerprint: string;
          tenant_id: string;
          wallet_id: string;
        };
        Insert: {
          allocation_policy_version_id: string;
          currency_code: string;
          financial_transaction_id: string;
          gross_amount: number;
          id?: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference?: string;
          owner_user_id: string;
          recorded_at?: string;
          recorded_by_user_id: string;
          request_fingerprint: string;
          tenant_id: string;
          wallet_id: string;
        };
        Update: {
          allocation_policy_version_id?: string;
          currency_code?: string;
          financial_transaction_id?: string;
          gross_amount?: number;
          id?: string;
          idempotency_key?: string;
          membership_id?: string;
          office_id?: string;
          operation_reference?: string;
          owner_user_id?: string;
          recorded_at?: string;
          recorded_by_user_id?: string;
          request_fingerprint?: string;
          tenant_id?: string;
          wallet_id?: string;
        };
        Relationships: [];
      };
      payout_account_command_idempotency: {
        Row: {
          actor_user_id: string;
          command_type: string;
          created_at: string;
          idempotency_key: string;
          payout_account_id: string;
          request_fingerprint: string;
          result_status:
            Database["financial_ops"]["Enums"]["payout_account_status"];
          tenant_id: string;
        };
        Insert: {
          actor_user_id: string;
          command_type: string;
          created_at?: string;
          idempotency_key: string;
          payout_account_id: string;
          request_fingerprint: string;
          result_status:
            Database["financial_ops"]["Enums"]["payout_account_status"];
          tenant_id: string;
        };
        Update: {
          actor_user_id?: string;
          command_type?: string;
          created_at?: string;
          idempotency_key?: string;
          payout_account_id?: string;
          request_fingerprint?: string;
          result_status?:
            Database["financial_ops"]["Enums"]["payout_account_status"];
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "payout_account_command_idempotency_payout_account_id_fkey";
            columns: ["payout_account_id"];
            isOneToOne: false;
            referencedRelation: "payout_accounts";
            referencedColumns: ["id"];
          },
        ];
      };
      payout_accounts: {
        Row: {
          account_holder_name: string;
          account_reference: string;
          country_code: string;
          created_at: string;
          deactivated_at: string | null;
          id: string;
          institution_code: string;
          institution_name: string;
          is_primary: boolean;
          owner_user_id: string;
          payout_currency: string;
          payout_rail: string;
          provider_metadata: Json;
          replaced_by_account_id: string | null;
          status: Database["financial_ops"]["Enums"]["payout_account_status"];
          verification_method: string | null;
          verification_status:
            Database["financial_ops"]["Enums"]["payout_verification_status"];
          verified_at: string | null;
          wallet_id: string;
        };
        Insert: {
          account_holder_name: string;
          account_reference: string;
          country_code: string;
          created_at?: string;
          deactivated_at?: string | null;
          id?: string;
          institution_code: string;
          institution_name: string;
          is_primary?: boolean;
          owner_user_id: string;
          payout_currency: string;
          payout_rail: string;
          provider_metadata?: Json;
          replaced_by_account_id?: string | null;
          status?: Database["financial_ops"]["Enums"]["payout_account_status"];
          verification_method?: string | null;
          verification_status:
            Database["financial_ops"]["Enums"]["payout_verification_status"];
          verified_at?: string | null;
          wallet_id: string;
        };
        Update: {
          account_holder_name?: string;
          account_reference?: string;
          country_code?: string;
          created_at?: string;
          deactivated_at?: string | null;
          id?: string;
          institution_code?: string;
          institution_name?: string;
          is_primary?: boolean;
          owner_user_id?: string;
          payout_currency?: string;
          payout_rail?: string;
          provider_metadata?: Json;
          replaced_by_account_id?: string | null;
          status?: Database["financial_ops"]["Enums"]["payout_account_status"];
          verification_method?: string | null;
          verification_status?:
            Database["financial_ops"]["Enums"]["payout_verification_status"];
          verified_at?: string | null;
          wallet_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "payout_accounts_replaced_by_account_id_fkey";
            columns: ["replaced_by_account_id"];
            isOneToOne: false;
            referencedRelation: "payout_accounts";
            referencedColumns: ["id"];
          },
        ];
      };
      payout_assertion_evidence: {
        Row: {
          evidence_id: string;
          linked_at: string;
          payout_assertion_revision_id: string;
        };
        Insert: {
          evidence_id: string;
          linked_at?: string;
          payout_assertion_revision_id: string;
        };
        Update: {
          evidence_id?: string;
          linked_at?: string;
          payout_assertion_revision_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "payout_assertion_evidence_payout_assertion_revision_id_fkey";
            columns: ["payout_assertion_revision_id"];
            isOneToOne: false;
            referencedRelation: "payout_assertion_revisions";
            referencedColumns: ["id"];
          },
        ];
      };
      payout_assertion_revisions: {
        Row: {
          beneficiary_payout_amount: number;
          created_at: string;
          id: string;
          notes: string | null;
          paid_at: string;
          payout_assertion_id: string;
          payout_currency: string;
          provider: string;
          provider_fee_amount: number;
          provider_fee_currency: string | null;
          provider_reference: string | null;
          revision_number: number;
          submitted_by_user_id: string;
          wallet_debit_amount: number;
        };
        Insert: {
          beneficiary_payout_amount: number;
          created_at?: string;
          id?: string;
          notes?: string | null;
          paid_at: string;
          payout_assertion_id: string;
          payout_currency: string;
          provider: string;
          provider_fee_amount?: number;
          provider_fee_currency?: string | null;
          provider_reference?: string | null;
          revision_number: number;
          submitted_by_user_id: string;
          wallet_debit_amount: number;
        };
        Update: {
          beneficiary_payout_amount?: number;
          created_at?: string;
          id?: string;
          notes?: string | null;
          paid_at?: string;
          payout_assertion_id?: string;
          payout_currency?: string;
          provider?: string;
          provider_fee_amount?: number;
          provider_fee_currency?: string | null;
          provider_reference?: string | null;
          revision_number?: number;
          submitted_by_user_id?: string;
          wallet_debit_amount?: number;
        };
        Relationships: [
          {
            foreignKeyName:
              "payout_assertion_revisions_payout_assertion_id_fkey";
            columns: ["payout_assertion_id"];
            isOneToOne: false;
            referencedRelation: "payout_completion_assertions";
            referencedColumns: ["id"];
          },
        ];
      };
      payout_command_idempotency: {
        Row: {
          actor_user_id: string;
          command_type: string;
          created_at: string;
          idempotency_key: string;
          payout_assertion_id: string;
          request_fingerprint: string;
          result_assertion_status:
            Database["financial_ops"]["Enums"]["payout_assertion_status"];
          result_withdrawal_status:
            Database["financial_ops"]["Enums"]["withdrawal_status"];
        };
        Insert: {
          actor_user_id: string;
          command_type: string;
          created_at?: string;
          idempotency_key: string;
          payout_assertion_id: string;
          request_fingerprint: string;
          result_assertion_status:
            Database["financial_ops"]["Enums"]["payout_assertion_status"];
          result_withdrawal_status:
            Database["financial_ops"]["Enums"]["withdrawal_status"];
        };
        Update: {
          actor_user_id?: string;
          command_type?: string;
          created_at?: string;
          idempotency_key?: string;
          payout_assertion_id?: string;
          request_fingerprint?: string;
          result_assertion_status?:
            Database["financial_ops"]["Enums"]["payout_assertion_status"];
          result_withdrawal_status?:
            Database["financial_ops"]["Enums"]["withdrawal_status"];
        };
        Relationships: [
          {
            foreignKeyName:
              "payout_command_idempotency_payout_assertion_id_fkey";
            columns: ["payout_assertion_id"];
            isOneToOne: false;
            referencedRelation: "payout_completion_assertions";
            referencedColumns: ["id"];
          },
        ];
      };
      payout_completion_assertions: {
        Row: {
          accepted_at: string | null;
          accepted_via:
            | Database["financial_ops"]["Enums"]["payout_resolution"]
            | null;
          assertion_number: number;
          current_revision_number: number;
          id: string;
          posted_financial_transaction_id: string | null;
          status: Database["financial_ops"]["Enums"]["payout_assertion_status"];
          submitted_at: string;
          submitted_by_user_id: string;
          updated_at: string;
          version: number;
          withdrawal_id: string;
        };
        Insert: {
          accepted_at?: string | null;
          accepted_via?:
            | Database["financial_ops"]["Enums"]["payout_resolution"]
            | null;
          assertion_number: number;
          current_revision_number?: number;
          id?: string;
          posted_financial_transaction_id?: string | null;
          status?:
            Database["financial_ops"]["Enums"]["payout_assertion_status"];
          submitted_at?: string;
          submitted_by_user_id: string;
          updated_at?: string;
          version?: number;
          withdrawal_id: string;
        };
        Update: {
          accepted_at?: string | null;
          accepted_via?:
            | Database["financial_ops"]["Enums"]["payout_resolution"]
            | null;
          assertion_number?: number;
          current_revision_number?: number;
          id?: string;
          posted_financial_transaction_id?: string | null;
          status?:
            Database["financial_ops"]["Enums"]["payout_assertion_status"];
          submitted_at?: string;
          submitted_by_user_id?: string;
          updated_at?: string;
          version?: number;
          withdrawal_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "payout_completion_assertions_withdrawal_id_fkey";
            columns: ["withdrawal_id"];
            isOneToOne: false;
            referencedRelation: "withdrawal_requests";
            referencedColumns: ["id"];
          },
        ];
      };
      pocket_transfer_commands: {
        Row: {
          actor_user_id: string;
          created_at: string;
          idempotency_key: string;
          request_fingerprint: string;
          result: Database["financial_ops"]["CompositeTypes"][
            "financial_operation_result"
          ];
        };
        Insert: {
          actor_user_id: string;
          created_at?: string;
          idempotency_key: string;
          request_fingerprint: string;
          result: Database["financial_ops"]["CompositeTypes"][
            "financial_operation_result"
          ];
        };
        Update: {
          actor_user_id?: string;
          created_at?: string;
          idempotency_key?: string;
          request_fingerprint?: string;
          result?: Database["financial_ops"]["CompositeTypes"][
            "financial_operation_result"
          ];
        };
        Relationships: [];
      };
      pocket_transfer_requests: {
        Row: {
          amount: number;
          approved_at: string | null;
          approved_by_user_id: string | null;
          cancellation_reason: string | null;
          cancelled_at: string | null;
          cancelled_by_user_id: string | null;
          created_at: string;
          currency_code: string;
          destination_ledger_account_id: string;
          financial_transaction_id: string | null;
          id: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference: string;
          owner_user_id: string;
          rejected_at: string | null;
          rejected_by_user_id: string | null;
          rejection_reason: string | null;
          request_fingerprint: string;
          requested_by_user_id: string;
          source_ledger_account_id: string;
          status: Database["financial_ops"]["Enums"]["pocket_transfer_status"];
          tenant_id: string;
          updated_at: string;
          version: number;
          wallet_id: string;
        };
        Insert: {
          amount: number;
          approved_at?: string | null;
          approved_by_user_id?: string | null;
          cancellation_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by_user_id?: string | null;
          created_at?: string;
          currency_code: string;
          destination_ledger_account_id: string;
          financial_transaction_id?: string | null;
          id?: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference?: string;
          owner_user_id: string;
          rejected_at?: string | null;
          rejected_by_user_id?: string | null;
          rejection_reason?: string | null;
          request_fingerprint: string;
          requested_by_user_id: string;
          source_ledger_account_id: string;
          status?: Database["financial_ops"]["Enums"]["pocket_transfer_status"];
          tenant_id: string;
          updated_at?: string;
          version?: number;
          wallet_id: string;
        };
        Update: {
          amount?: number;
          approved_at?: string | null;
          approved_by_user_id?: string | null;
          cancellation_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by_user_id?: string | null;
          created_at?: string;
          currency_code?: string;
          destination_ledger_account_id?: string;
          financial_transaction_id?: string | null;
          id?: string;
          idempotency_key?: string;
          membership_id?: string;
          office_id?: string;
          operation_reference?: string;
          owner_user_id?: string;
          rejected_at?: string | null;
          rejected_by_user_id?: string | null;
          rejection_reason?: string | null;
          request_fingerprint?: string;
          requested_by_user_id?: string;
          source_ledger_account_id?: string;
          status?: Database["financial_ops"]["Enums"]["pocket_transfer_status"];
          tenant_id?: string;
          updated_at?: string;
          version?: number;
          wallet_id?: string;
        };
        Relationships: [];
      };
      pocket_transfer_reservations: {
        Row: {
          amount: number;
          consumed_at: string | null;
          created_at: string;
          ledger_account_id: string;
          pocket_transfer_id: string;
          release_reason: string | null;
          released_at: string | null;
          status: Database["financial_ops"]["Enums"]["reservation_status"];
        };
        Insert: {
          amount: number;
          consumed_at?: string | null;
          created_at?: string;
          ledger_account_id: string;
          pocket_transfer_id: string;
          release_reason?: string | null;
          released_at?: string | null;
          status?: Database["financial_ops"]["Enums"]["reservation_status"];
        };
        Update: {
          amount?: number;
          consumed_at?: string | null;
          created_at?: string;
          ledger_account_id?: string;
          pocket_transfer_id?: string;
          release_reason?: string | null;
          released_at?: string | null;
          status?: Database["financial_ops"]["Enums"]["reservation_status"];
        };
        Relationships: [
          {
            foreignKeyName:
              "pocket_transfer_reservations_pocket_transfer_id_fkey";
            columns: ["pocket_transfer_id"];
            isOneToOne: true;
            referencedRelation: "pocket_transfer_requests";
            referencedColumns: ["id"];
          },
        ];
      };
      returned_fund_revisions: {
        Row: {
          correction_idempotency_key: string | null;
          created_at: string;
          id: string;
          notes: string | null;
          provider: string;
          provider_reference: string | null;
          returned_at: string;
          returned_fund_id: string;
          revision_number: number;
          submitted_by_user_id: string;
        };
        Insert: {
          correction_idempotency_key?: string | null;
          created_at?: string;
          id?: string;
          notes?: string | null;
          provider: string;
          provider_reference?: string | null;
          returned_at: string;
          returned_fund_id: string;
          revision_number: number;
          submitted_by_user_id: string;
        };
        Update: {
          correction_idempotency_key?: string | null;
          created_at?: string;
          id?: string;
          notes?: string | null;
          provider?: string;
          provider_reference?: string | null;
          returned_at?: string;
          returned_fund_id?: string;
          revision_number?: number;
          submitted_by_user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "returned_fund_revisions_returned_fund_id_fkey";
            columns: ["returned_fund_id"];
            isOneToOne: false;
            referencedRelation: "returned_funds";
            referencedColumns: ["id"];
          },
        ];
      };
      returned_funds: {
        Row: {
          accepted_at: string | null;
          accepted_via:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          amount: number;
          currency_code: string;
          current_revision_number: number;
          destination_ledger_account_id: string;
          id: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference: string;
          owner_user_id: string;
          posted_financial_transaction_id: string | null;
          request_fingerprint: string;
          status:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at: string;
          submitted_by_user_id: string;
          tenant_id: string;
          updated_at: string;
          version: number;
          wallet_id: string;
          withdrawal_id: string;
        };
        Insert: {
          accepted_at?: string | null;
          accepted_via?:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          amount: number;
          currency_code: string;
          current_revision_number?: number;
          destination_ledger_account_id: string;
          id?: string;
          idempotency_key: string;
          membership_id: string;
          office_id: string;
          operation_reference?: string;
          owner_user_id: string;
          posted_financial_transaction_id?: string | null;
          request_fingerprint: string;
          status?:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at?: string;
          submitted_by_user_id: string;
          tenant_id: string;
          updated_at?: string;
          version?: number;
          wallet_id: string;
          withdrawal_id: string;
        };
        Update: {
          accepted_at?: string | null;
          accepted_via?:
            | Database["financial_ops"]["Enums"][
              "evidence_operation_resolution"
            ]
            | null;
          amount?: number;
          currency_code?: string;
          current_revision_number?: number;
          destination_ledger_account_id?: string;
          id?: string;
          idempotency_key?: string;
          membership_id?: string;
          office_id?: string;
          operation_reference?: string;
          owner_user_id?: string;
          posted_financial_transaction_id?: string | null;
          request_fingerprint?: string;
          status?:
            Database["financial_ops"]["Enums"]["evidence_operation_status"];
          submitted_at?: string;
          submitted_by_user_id?: string;
          tenant_id?: string;
          updated_at?: string;
          version?: number;
          wallet_id?: string;
          withdrawal_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "returned_funds_withdrawal_id_fkey";
            columns: ["withdrawal_id"];
            isOneToOne: false;
            referencedRelation: "withdrawal_requests";
            referencedColumns: ["id"];
          },
        ];
      };
      tenant_financial_settings: {
        Row: {
          adjustment_evidence_required: boolean;
          tenant_id: string;
          updated_at: string;
          updated_by_user_id: string;
          version: number;
        };
        Insert: {
          adjustment_evidence_required?: boolean;
          tenant_id: string;
          updated_at?: string;
          updated_by_user_id: string;
          version?: number;
        };
        Update: {
          adjustment_evidence_required?: boolean;
          tenant_id?: string;
          updated_at?: string;
          updated_by_user_id?: string;
          version?: number;
        };
        Relationships: [];
      };
      withdrawal_command_idempotency: {
        Row: {
          actor_user_id: string;
          command_type: string;
          created_at: string;
          idempotency_key: string;
          request_fingerprint: string;
          result_status:
            Database["financial_ops"]["Enums"]["withdrawal_status"];
          withdrawal_id: string;
        };
        Insert: {
          actor_user_id: string;
          command_type: string;
          created_at?: string;
          idempotency_key: string;
          request_fingerprint: string;
          result_status:
            Database["financial_ops"]["Enums"]["withdrawal_status"];
          withdrawal_id: string;
        };
        Update: {
          actor_user_id?: string;
          command_type?: string;
          created_at?: string;
          idempotency_key?: string;
          request_fingerprint?: string;
          result_status?:
            Database["financial_ops"]["Enums"]["withdrawal_status"];
          withdrawal_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "withdrawal_command_idempotency_withdrawal_id_fkey";
            columns: ["withdrawal_id"];
            isOneToOne: false;
            referencedRelation: "withdrawal_requests";
            referencedColumns: ["id"];
          },
        ];
      };
      withdrawal_destination_snapshots: {
        Row: {
          account_holder_name: string;
          account_reference: string;
          country_code: string;
          institution_code: string;
          institution_name: string;
          payout_currency: string;
          payout_rail: string;
          snapshotted_at: string;
          source_payout_account_id: string;
          verification_method: string;
          verification_status:
            Database["financial_ops"]["Enums"]["payout_verification_status"];
          withdrawal_id: string;
        };
        Insert: {
          account_holder_name: string;
          account_reference: string;
          country_code: string;
          institution_code: string;
          institution_name: string;
          payout_currency: string;
          payout_rail: string;
          snapshotted_at?: string;
          source_payout_account_id: string;
          verification_method: string;
          verification_status:
            Database["financial_ops"]["Enums"]["payout_verification_status"];
          withdrawal_id: string;
        };
        Update: {
          account_holder_name?: string;
          account_reference?: string;
          country_code?: string;
          institution_code?: string;
          institution_name?: string;
          payout_currency?: string;
          payout_rail?: string;
          snapshotted_at?: string;
          source_payout_account_id?: string;
          verification_method?: string;
          verification_status?:
            Database["financial_ops"]["Enums"]["payout_verification_status"];
          withdrawal_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "withdrawal_destination_snapshots_source_payout_account_id_fkey";
            columns: ["source_payout_account_id"];
            isOneToOne: false;
            referencedRelation: "payout_accounts";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName:
              "withdrawal_destination_snapshots_withdrawal_id_fkey";
            columns: ["withdrawal_id"];
            isOneToOne: true;
            referencedRelation: "withdrawal_requests";
            referencedColumns: ["id"];
          },
        ];
      };
      withdrawal_requests: {
        Row: {
          approved_at: string | null;
          approved_by_user_id: string | null;
          cancellation_reason: string | null;
          cancelled_at: string | null;
          cancelled_by_user_id: string | null;
          completed_at: string | null;
          created_at: string;
          financial_transaction_id: string | null;
          id: string;
          initiated_by_user_id: string;
          membership_id: string;
          office_id: string;
          owner_user_id: string;
          payout_account_id: string;
          rejected_at: string | null;
          rejected_by_user_id: string | null;
          rejection_reason: string | null;
          requested_amount: number;
          source_currency_code: string;
          source_ledger_account_id: string;
          source_pocket_key: string;
          status: Database["financial_ops"]["Enums"]["withdrawal_status"];
          tenant_id: string;
          updated_at: string;
          version: number;
          wallet_id: string;
          withdrawal_reference: string;
        };
        Insert: {
          approved_at?: string | null;
          approved_by_user_id?: string | null;
          cancellation_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by_user_id?: string | null;
          completed_at?: string | null;
          created_at?: string;
          financial_transaction_id?: string | null;
          id?: string;
          initiated_by_user_id: string;
          membership_id: string;
          office_id: string;
          owner_user_id: string;
          payout_account_id: string;
          rejected_at?: string | null;
          rejected_by_user_id?: string | null;
          rejection_reason?: string | null;
          requested_amount: number;
          source_currency_code: string;
          source_ledger_account_id: string;
          source_pocket_key: string;
          status?: Database["financial_ops"]["Enums"]["withdrawal_status"];
          tenant_id: string;
          updated_at?: string;
          version?: number;
          wallet_id: string;
          withdrawal_reference?: string;
        };
        Update: {
          approved_at?: string | null;
          approved_by_user_id?: string | null;
          cancellation_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by_user_id?: string | null;
          completed_at?: string | null;
          created_at?: string;
          financial_transaction_id?: string | null;
          id?: string;
          initiated_by_user_id?: string;
          membership_id?: string;
          office_id?: string;
          owner_user_id?: string;
          payout_account_id?: string;
          rejected_at?: string | null;
          rejected_by_user_id?: string | null;
          rejection_reason?: string | null;
          requested_amount?: number;
          source_currency_code?: string;
          source_ledger_account_id?: string;
          source_pocket_key?: string;
          status?: Database["financial_ops"]["Enums"]["withdrawal_status"];
          tenant_id?: string;
          updated_at?: string;
          version?: number;
          wallet_id?: string;
          withdrawal_reference?: string;
        };
        Relationships: [
          {
            foreignKeyName: "withdrawal_requests_payout_account_id_fkey";
            columns: ["payout_account_id"];
            isOneToOne: false;
            referencedRelation: "payout_accounts";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      add_payout_account: {
        Args: {
          p_account_holder_name: string;
          p_account_reference: string;
          p_actor_user_id: string;
          p_country_code: string;
          p_idempotency_key: string;
          p_institution_code: string;
          p_institution_name: string;
          p_make_primary?: boolean;
          p_payout_currency: string;
          p_payout_rail: string;
          p_session_id: string;
          p_tenant_id: string;
          p_wallet_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "payout_account_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "payout_account_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      approve_pocket_transfer: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_pocket_transfer_id: string;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      approve_withdrawal: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_session_id?: string;
          p_withdrawal_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "withdrawal_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "withdrawal_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      assert_currency_amount: {
        Args: { p_amount: number; p_currency_code: string };
        Returns: undefined;
      };
      authorize_bank_account_context: {
        Args: { p_actor: string; p_membership: string; p_session: string };
        Returns: Database["public"]["Tables"]["memberships"]["Row"];
        SetofOptions: {
          from: "*";
          to: "memberships";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      available_balance: {
        Args: { p_ledger_account_id: string };
        Returns: number;
      };
      bank_resolution_response: {
        Args: {
          p_intent:
            Database["financial_ops"]["Tables"]["bank_resolution_intents"][
              "Row"
            ];
        };
        Returns: Json;
      };
      calculate_policy_allocations: {
        Args: {
          p_cap_debt_at_zero?: boolean;
          p_currency_code: string;
          p_membership_id: string;
          p_policy_version_id: string;
          p_total_amount: number;
          p_wallet_id: string;
        };
        Returns: {
          allocated_amount: number;
          allocation_basis_points: number;
          ledger_account_id: string;
          pocket_key: string;
          remainder_rank: number;
        }[];
      };
      cancel_pocket_transfer: {
        Args: {
          p_actor_user_id: string;
          p_pocket_transfer_id: string;
          p_reason: string;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      cancel_withdrawal: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_reason: string;
          p_session_id?: string;
          p_withdrawal_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "withdrawal_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "withdrawal_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      clear_primary_payout_accounts: {
        Args: {
          p_payout_currency: string;
          p_payout_rail: string;
          p_wallet_id: string;
        };
        Returns: undefined;
      };
      complete_withdrawal_from_assertion: {
        Args: {
          p_payout_assertion_id: string;
          p_resolution: Database["financial_ops"]["Enums"]["payout_resolution"];
          p_resolution_actor_user_id?: string;
        };
        Returns:
          Database["ledger"]["CompositeTypes"]["post_transaction_result"];
        SetofOptions: {
          from: "*";
          to: "post_transaction_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      configure_adjustment_evidence_requirement: {
        Args: {
          p_actor_user_id: string;
          p_evidence_required: boolean;
          p_session_id?: string;
          p_tenant_id: string;
        };
        Returns: {
          adjustment_evidence_required: boolean;
          tenant_id: string;
          updated_at: string;
          updated_by_user_id: string;
          version: number;
        };
        SetofOptions: {
          from: "*";
          to: "tenant_financial_settings";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      correct_administrative_adjustment: {
        Args: {
          p_actor_user_id: string;
          p_administrative_adjustment_id: string;
          p_correction_idempotency_key: string;
          p_evidence_items: Json;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      correct_currency_conversion: {
        Args: {
          p_actor_user_id: string;
          p_converted_at: string;
          p_correction_idempotency_key: string;
          p_currency_conversion_id: string;
          p_destination_amount: number;
          p_effective_rate: number;
          p_evidence_items: Json;
          p_notes?: string;
          p_provider: string;
          p_provider_fee_amount?: number;
          p_provider_fee_currency?: string;
          p_provider_rate?: number;
          p_provider_reference?: string;
          p_session_id?: string;
          p_source_amount: number;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      correct_payout_assertion: {
        Args: {
          p_actor_user_id: string;
          p_beneficiary_payout_amount: number;
          p_evidence_items: Json;
          p_idempotency_key: string;
          p_notes?: string;
          p_paid_at: string;
          p_payout_assertion_id: string;
          p_payout_currency: string;
          p_provider: string;
          p_provider_fee_amount?: number;
          p_provider_reference?: string;
          p_session_id?: string;
          p_wallet_debit_amount: number;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "payout_assertion_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "payout_assertion_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      correct_returned_fund: {
        Args: {
          p_actor_user_id: string;
          p_correction_idempotency_key: string;
          p_evidence_items: Json;
          p_notes?: string;
          p_provider: string;
          p_provider_reference?: string;
          p_returned_at: string;
          p_returned_fund_id: string;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      deactivate_payout_account: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_payout_account_id: string;
          p_session_id: string;
          p_tenant_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "payout_account_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "payout_account_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      enforce_authorization: {
        Args: {
          p_decision:
            Database["authz"]["CompositeTypes"]["authorization_decision"];
        };
        Returns: undefined;
      };
      execute_scoped_transfer: {
        Args: {
          p_action: string;
          p_actor_membership_id: string;
          p_actor_user_id: string;
          p_amount: number;
          p_destination_ledger_account_id: string;
          p_idempotency_key: string;
          p_reason: string;
          p_session_id: string;
          p_source_ledger_account_id: string;
          p_transfer_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      generate_operation_reference: {
        Args: { p_prefix: string };
        Returns: string;
      };
      generate_withdrawal_reference: { Args: never; Returns: string };
      payout_account_request_fingerprint: {
        Args: { p_command_type: string; p_payload: Json };
        Returns: string;
      };
      post_administrative_adjustment: {
        Args: {
          p_actor_user_id: string;
          p_administrative_adjustment_id: string;
          p_posting_idempotency_key: string;
          p_resolution:
            Database["financial_ops"]["Enums"]["evidence_operation_resolution"];
        };
        Returns: string;
      };
      post_currency_conversion: {
        Args: {
          p_actor_user_id: string;
          p_currency_conversion_id: string;
          p_posting_idempotency_key: string;
          p_resolution:
            Database["financial_ops"]["Enums"]["evidence_operation_resolution"];
        };
        Returns: string;
      };
      post_returned_fund: {
        Args: {
          p_actor_user_id: string;
          p_posting_idempotency_key: string;
          p_resolution:
            Database["financial_ops"]["Enums"]["evidence_operation_resolution"];
          p_returned_fund_id: string;
        };
        Returns: string;
      };
      record_administrative_adjustment_verification: {
        Args: {
          p_administrative_adjustment_id: string;
          p_extracted_facts: Json;
          p_mismatch_reasons: Json;
          p_verification_request_id: string;
          p_verifier_name: string;
          p_verifier_version?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      record_authorization_audit: {
        Args: {
          p_decision:
            Database["authz"]["CompositeTypes"]["authorization_decision"];
          p_event_type: string;
          p_metadata?: Json;
          p_session_id: string;
          p_target_id: string;
        };
        Returns: undefined;
      };
      record_currency_conversion_verification: {
        Args: {
          p_currency_conversion_id: string;
          p_extracted_facts: Json;
          p_mismatch_reasons: Json;
          p_verification_request_id: string;
          p_verifier_name: string;
          p_verifier_version?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      record_income: {
        Args: {
          p_actor_user_id: string;
          p_currency_code: string;
          p_evidence_items: Json;
          p_gross_amount: number;
          p_idempotency_key: string;
          p_session_id?: string;
          p_target_membership_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      record_operation_authorization_audit: {
        Args: {
          p_decision:
            Database["authz"]["CompositeTypes"]["authorization_decision"];
          p_event_type: string;
          p_metadata?: Json;
          p_session_id: string;
          p_target_id: string;
          p_target_type: string;
        };
        Returns: undefined;
      };
      record_payout_account_change: {
        Args: {
          p_account_id: string;
          p_decision:
            Database["authz"]["CompositeTypes"]["authorization_decision"];
          p_event_type: string;
          p_metadata: Json;
          p_session_id: string;
          p_tenant_id: string;
        };
        Returns: undefined;
      };
      record_payout_verification: {
        Args: {
          p_extracted_facts: Json;
          p_mismatch_reasons: Json;
          p_payout_assertion_id: string;
          p_verification_request_id: string;
          p_verifier_name: string;
          p_verifier_version?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "payout_assertion_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "payout_assertion_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      record_returned_fund_verification: {
        Args: {
          p_extracted_facts: Json;
          p_mismatch_reasons: Json;
          p_returned_fund_id: string;
          p_verification_request_id: string;
          p_verifier_name: string;
          p_verifier_version?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      reject_pocket_transfer: {
        Args: {
          p_actor_user_id: string;
          p_pocket_transfer_id: string;
          p_reason: string;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      reject_withdrawal: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_reason: string;
          p_session_id?: string;
          p_withdrawal_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "withdrawal_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "withdrawal_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      replace_payout_account: {
        Args: {
          p_account_holder_name: string;
          p_account_reference: string;
          p_actor_user_id: string;
          p_country_code: string;
          p_existing_payout_account_id: string;
          p_idempotency_key: string;
          p_institution_code: string;
          p_institution_name: string;
          p_make_primary?: boolean;
          p_payout_currency: string;
          p_payout_rail: string;
          p_session_id: string;
          p_tenant_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "payout_account_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "payout_account_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      require_command_actor: {
        Args: { p_actor_user_id: string };
        Returns: undefined;
      };
      require_system_account: {
        Args: { p_currency_code: string; p_system_account_key: string };
        Returns: string;
      };
      require_transfer_context: {
        Args: {
          p_actor_membership_id: string;
          p_actor_user_id: string;
          p_office_id: string;
          p_owner_user_id: string;
          p_tenant_id: string;
        };
        Returns: undefined;
      };
      reverse_financial_transaction: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_original_financial_transaction_id: string;
          p_reason: string;
          p_session_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      review_administrative_adjustment: {
        Args: {
          p_actor_user_id: string;
          p_administrative_adjustment_id: string;
          p_decision: Database["evidence"]["Enums"]["review_decision"];
          p_idempotency_key: string;
          p_review_note: string;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      review_currency_conversion: {
        Args: {
          p_actor_user_id: string;
          p_currency_conversion_id: string;
          p_decision: Database["evidence"]["Enums"]["review_decision"];
          p_idempotency_key: string;
          p_review_note: string;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      review_payout_assertion: {
        Args: {
          p_actor_user_id: string;
          p_decision: Database["evidence"]["Enums"]["review_decision"];
          p_idempotency_key: string;
          p_payout_assertion_id: string;
          p_review_note: string;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "payout_assertion_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "payout_assertion_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      review_returned_fund: {
        Args: {
          p_actor_user_id: string;
          p_decision: Database["evidence"]["Enums"]["review_decision"];
          p_idempotency_key: string;
          p_returned_fund_id: string;
          p_review_note: string;
          p_session_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      set_primary_payout_account: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_payout_account_id: string;
          p_session_id: string;
          p_tenant_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "payout_account_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "payout_account_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      submit_administrative_adjustment: {
        Args: {
          p_actor_user_id: string;
          p_amount: number;
          p_currency_code: string;
          p_direction:
            Database["financial_ops"]["Enums"]["adjustment_direction"];
          p_evidence_items: Json;
          p_idempotency_key: string;
          p_reason: string;
          p_session_id?: string;
          p_target_membership_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      submit_currency_conversion: {
        Args: {
          p_actor_user_id: string;
          p_converted_at: string;
          p_destination_amount: number;
          p_destination_ledger_account_id: string;
          p_effective_rate: number;
          p_evidence_items: Json;
          p_idempotency_key: string;
          p_notes?: string;
          p_provider: string;
          p_provider_fee_amount?: number;
          p_provider_fee_currency?: string;
          p_provider_rate?: number;
          p_provider_reference?: string;
          p_session_id?: string;
          p_source_amount: number;
          p_source_ledger_account_id: string;
          p_withdrawal_id?: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      submit_payout_assertion: {
        Args: {
          p_actor_user_id: string;
          p_beneficiary_payout_amount: number;
          p_evidence_items: Json;
          p_idempotency_key: string;
          p_notes?: string;
          p_paid_at: string;
          p_payout_currency: string;
          p_provider: string;
          p_provider_fee_amount?: number;
          p_provider_reference?: string;
          p_session_id?: string;
          p_wallet_debit_amount: number;
          p_withdrawal_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "payout_assertion_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "payout_assertion_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      submit_pocket_transfer: {
        Args: {
          p_actor_user_id: string;
          p_amount: number;
          p_destination_ledger_account_id: string;
          p_idempotency_key: string;
          p_session_id?: string;
          p_source_ledger_account_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      submit_returned_fund: {
        Args: {
          p_actor_user_id: string;
          p_amount: number;
          p_evidence_items: Json;
          p_idempotency_key: string;
          p_notes?: string;
          p_provider: string;
          p_provider_reference?: string;
          p_returned_at: string;
          p_session_id?: string;
          p_withdrawal_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "financial_operation_result"
        ];
        SetofOptions: {
          from: "*";
          to: "financial_operation_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      submit_withdrawal: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_payout_account_id: string;
          p_requested_amount: number;
          p_session_id?: string;
          p_source_ledger_account_id: string;
        };
        Returns: Database["financial_ops"]["CompositeTypes"][
          "withdrawal_command_result"
        ];
        SetofOptions: {
          from: "*";
          to: "withdrawal_command_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      transfer_decision_covers_context: {
        Args: {
          p_actor_membership_id: string;
          p_decision:
            Database["authz"]["CompositeTypes"]["authorization_decision"];
          p_target_office_id: string;
        };
        Returns: boolean;
      };
      validate_direct_payout_facts: {
        Args: {
          p_beneficiary_payout_amount: number;
          p_paid_at: string;
          p_payout_currency: string;
          p_provider_fee_amount: number;
          p_wallet_debit_amount: number;
          p_withdrawal_id: string;
        };
        Returns: undefined;
      };
    };
    Enums: {
      adjustment_direction: "credit" | "debit";
      evidence_operation_resolution: "automated_match" | "manual_clear";
      evidence_operation_status:
        | "submitted"
        | "correction_required"
        | "needs_review"
        | "rejected"
        | "posted";
      payout_account_status: "active" | "deactivated" | "replaced";
      payout_assertion_status:
        | "submitted"
        | "correction_required"
        | "needs_review"
        | "rejected"
        | "posted";
      payout_resolution: "automated_match" | "manual_clear";
      payout_verification_status: "pending" | "verified" | "rejected";
      pocket_transfer_status:
        | "requested"
        | "completed"
        | "rejected"
        | "cancelled";
      reservation_status: "active" | "consumed" | "released";
      withdrawal_status:
        | "requested"
        | "approved"
        | "completed"
        | "cancelled"
        | "rejected";
    };
    CompositeTypes: {
      financial_operation_result: {
        operation_id: string | null;
        operation_reference: string | null;
        status: string | null;
        financial_transaction_id: string | null;
        reused: boolean | null;
      };
      payout_account_command_result: {
        payout_account_id: string | null;
        status:
          | Database["financial_ops"]["Enums"]["payout_account_status"]
          | null;
        reused: boolean | null;
      };
      payout_assertion_command_result: {
        payout_assertion_id: string | null;
        payout_assertion_status:
          | Database["financial_ops"]["Enums"]["payout_assertion_status"]
          | null;
        withdrawal_id: string | null;
        withdrawal_status:
          | Database["financial_ops"]["Enums"]["withdrawal_status"]
          | null;
        reused: boolean | null;
      };
      withdrawal_command_result: {
        withdrawal_id: string | null;
        withdrawal_reference: string | null;
        status: Database["financial_ops"]["Enums"]["withdrawal_status"] | null;
        reused: boolean | null;
      };
    };
  };
  internal: {
    Tables: {
      development_networks: {
        Row: {
          created_at: string;
          created_by_user_id: string;
          setup_token_digest: string;
          tenant_id: string;
        };
        Insert: {
          created_at?: string;
          created_by_user_id: string;
          setup_token_digest: string;
          tenant_id: string;
        };
        Update: {
          created_at?: string;
          created_by_user_id?: string;
          setup_token_digest?: string;
          tenant_id?: string;
        };
        Relationships: [];
      };
      integration_delivery_attempts: {
        Row: {
          attempt_number: number;
          delivery_cycle: number;
          error_code: string | null;
          finished_at: string;
          id: string;
          latency_ms: number | null;
          lease_token: string;
          outbox_event_id: string;
          outcome: Database["internal"]["Enums"]["integration_attempt_outcome"];
          provider: string | null;
          provider_reference: string | null;
          provider_status_code: number | null;
          started_at: string;
          worker_id: string;
        };
        Insert: {
          attempt_number: number;
          delivery_cycle: number;
          error_code?: string | null;
          finished_at?: string;
          id?: string;
          latency_ms?: number | null;
          lease_token: string;
          outbox_event_id: string;
          outcome: Database["internal"]["Enums"]["integration_attempt_outcome"];
          provider?: string | null;
          provider_reference?: string | null;
          provider_status_code?: number | null;
          started_at: string;
          worker_id: string;
        };
        Update: {
          attempt_number?: number;
          delivery_cycle?: number;
          error_code?: string | null;
          finished_at?: string;
          id?: string;
          latency_ms?: number | null;
          lease_token?: string;
          outbox_event_id?: string;
          outcome?:
            Database["internal"]["Enums"]["integration_attempt_outcome"];
          provider?: string | null;
          provider_reference?: string | null;
          provider_status_code?: number | null;
          started_at?: string;
          worker_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "integration_delivery_attempts_outbox_event_id_fkey";
            columns: ["outbox_event_id"];
            isOneToOne: false;
            referencedRelation: "outbox_events";
            referencedColumns: ["id"];
          },
        ];
      };
      organization_command_idempotency: {
        Row: {
          actor_user_id: string;
          command_type: string;
          created_at: string;
          idempotency_key: string;
          request_fingerprint: string;
          result_id: string;
          result_type: string;
          tenant_id: string;
        };
        Insert: {
          actor_user_id: string;
          command_type: string;
          created_at?: string;
          idempotency_key: string;
          request_fingerprint: string;
          result_id: string;
          result_type: string;
          tenant_id: string;
        };
        Update: {
          actor_user_id?: string;
          command_type?: string;
          created_at?: string;
          idempotency_key?: string;
          request_fingerprint?: string;
          result_id?: string;
          result_type?: string;
          tenant_id?: string;
        };
        Relationships: [];
      };
      outbox_delivery_requeues: {
        Row: {
          id: string;
          new_delivery_cycle: number;
          operator_reference: string;
          outbox_event_id: string;
          previous_delivery_cycle: number;
          reason_code: string;
          requeued_at: string;
        };
        Insert: {
          id?: string;
          new_delivery_cycle: number;
          operator_reference: string;
          outbox_event_id: string;
          previous_delivery_cycle: number;
          reason_code: string;
          requeued_at?: string;
        };
        Update: {
          id?: string;
          new_delivery_cycle?: number;
          operator_reference?: string;
          outbox_event_id?: string;
          previous_delivery_cycle?: number;
          reason_code?: string;
          requeued_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "outbox_delivery_requeues_outbox_event_id_fkey";
            columns: ["outbox_event_id"];
            isOneToOne: false;
            referencedRelation: "outbox_events";
            referencedColumns: ["id"];
          },
        ];
      };
      outbox_delivery_state: {
        Row: {
          attempt_count: number;
          created_at: string;
          dead_lettered_at: string | null;
          delivered_at: string | null;
          delivery_cycle: number;
          last_error_code: string | null;
          lease_expires_at: string | null;
          lease_started_at: string | null;
          lease_token: string | null;
          leased_by: string | null;
          max_attempts: number;
          next_attempt_at: string | null;
          outbox_event_id: string;
          status: Database["internal"]["Enums"]["integration_delivery_status"];
          updated_at: string;
        };
        Insert: {
          attempt_count?: number;
          created_at?: string;
          dead_lettered_at?: string | null;
          delivered_at?: string | null;
          delivery_cycle?: number;
          last_error_code?: string | null;
          lease_expires_at?: string | null;
          lease_started_at?: string | null;
          lease_token?: string | null;
          leased_by?: string | null;
          max_attempts?: number;
          next_attempt_at?: string | null;
          outbox_event_id: string;
          status?: Database["internal"]["Enums"]["integration_delivery_status"];
          updated_at?: string;
        };
        Update: {
          attempt_count?: number;
          created_at?: string;
          dead_lettered_at?: string | null;
          delivered_at?: string | null;
          delivery_cycle?: number;
          last_error_code?: string | null;
          lease_expires_at?: string | null;
          lease_started_at?: string | null;
          lease_token?: string | null;
          leased_by?: string | null;
          max_attempts?: number;
          next_attempt_at?: string | null;
          outbox_event_id?: string;
          status?: Database["internal"]["Enums"]["integration_delivery_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "outbox_delivery_state_outbox_event_id_fkey";
            columns: ["outbox_event_id"];
            isOneToOne: true;
            referencedRelation: "outbox_events";
            referencedColumns: ["id"];
          },
        ];
      };
      outbox_events: {
        Row: {
          aggregate_id: string;
          aggregate_type: string;
          available_at: string;
          event_type: string;
          id: string;
          occurred_at: string;
          payload: Json;
          tenant_id: string | null;
        };
        Insert: {
          aggregate_id: string;
          aggregate_type: string;
          available_at?: string;
          event_type: string;
          id?: string;
          occurred_at?: string;
          payload?: Json;
          tenant_id?: string | null;
        };
        Update: {
          aggregate_id?: string;
          aggregate_type?: string;
          available_at?: string;
          event_type?: string;
          id?: string;
          occurred_at?: string;
          payload?: Json;
          tenant_id?: string | null;
        };
        Relationships: [];
      };
      payout_verification_jobs: {
        Row: {
          assertion_id: string;
          attempt_number: number;
          created_at: string;
          cycle: number;
          destination: Json;
          facts: Json;
          files: Json;
          id: string;
          last_error_code: string | null;
          lease_expires_at: string | null;
          lease_token: string | null;
          next_attempt_at: string | null;
          revision_id: string;
          revision_number: number;
          stage_id: string;
          status: string;
          updated_at: string;
          withdrawal_id: string;
          worker_id: string | null;
        };
        Insert: {
          assertion_id: string;
          attempt_number?: number;
          created_at?: string;
          cycle?: number;
          destination: Json;
          facts: Json;
          files: Json;
          id?: string;
          last_error_code?: string | null;
          lease_expires_at?: string | null;
          lease_token?: string | null;
          next_attempt_at?: string | null;
          revision_id: string;
          revision_number: number;
          stage_id: string;
          status?: string;
          updated_at?: string;
          withdrawal_id: string;
          worker_id?: string | null;
        };
        Update: {
          assertion_id?: string;
          attempt_number?: number;
          created_at?: string;
          cycle?: number;
          destination?: Json;
          facts?: Json;
          files?: Json;
          id?: string;
          last_error_code?: string | null;
          lease_expires_at?: string | null;
          lease_token?: string | null;
          next_attempt_at?: string | null;
          revision_id?: string;
          revision_number?: number;
          stage_id?: string;
          status?: string;
          updated_at?: string;
          withdrawal_id?: string;
          worker_id?: string | null;
        };
        Relationships: [];
      };
      payout_verification_results: {
        Row: {
          created_at: string;
          job_id: string;
          lease_token: string;
          request_fingerprint: string;
          response: Json;
          revision_id: string;
          worker_id: string;
        };
        Insert: {
          created_at?: string;
          job_id: string;
          lease_token: string;
          request_fingerprint: string;
          response: Json;
          revision_id: string;
          worker_id: string;
        };
        Update: {
          created_at?: string;
          job_id?: string;
          lease_token?: string;
          request_fingerprint?: string;
          response?: Json;
          revision_id?: string;
          worker_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "payout_verification_results_job_id_fkey";
            columns: ["job_id"];
            isOneToOne: false;
            referencedRelation: "payout_verification_jobs";
            referencedColumns: ["id"];
          },
        ];
      };
      payout_verification_retries: {
        Row: {
          actor_user_id: string;
          assertion_id: string;
          created_at: string;
          idempotency_key: string;
          job_id: string;
          response: Json;
        };
        Insert: {
          actor_user_id: string;
          assertion_id: string;
          created_at?: string;
          idempotency_key: string;
          job_id: string;
          response: Json;
        };
        Update: {
          actor_user_id?: string;
          assertion_id?: string;
          created_at?: string;
          idempotency_key?: string;
          job_id?: string;
          response?: Json;
        };
        Relationships: [
          {
            foreignKeyName: "payout_verification_retries_job_id_fkey";
            columns: ["job_id"];
            isOneToOne: false;
            referencedRelation: "payout_verification_jobs";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      accept_invitation: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_token_digest: string;
        };
        Returns: string;
      };
      activate_membership: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_membership_id: string;
          p_session_id: string;
        };
        Returns: string;
      };
      assert_membership_not_billing_owner: {
        Args: { p_membership_id: string; p_tenant_id: string };
        Returns: undefined;
      };
      bootstrap_development_network: {
        Args: {
          p_actor_user_id: string;
          p_network_name: string;
          p_setup_token_digest: string;
        };
        Returns: string;
      };
      bump_membership_authorization_versions: {
        Args: { p_tenant_id: string; p_user_id: string };
        Returns: undefined;
      };
      claim_outbox_deliveries: {
        Args: {
          p_batch_size?: number;
          p_lease_seconds?: number;
          p_now?: string;
          p_worker_id: string;
        };
        Returns:
          Database["internal"]["CompositeTypes"]["outbox_delivery_claim"][];
        SetofOptions: {
          from: "*";
          to: "outbox_delivery_claim";
          isOneToOne: false;
          isSetofReturn: true;
        };
      };
      complete_outbox_delivery: {
        Args: {
          p_latency_ms?: number;
          p_lease_token: string;
          p_now?: string;
          p_outbox_event_id: string;
          p_provider: string;
          p_provider_reference?: string;
          p_provider_status_code?: number;
        };
        Returns: boolean;
      };
      create_invitation: {
        Args: {
          p_actor_user_id: string;
          p_email: string;
          p_expires_at: string;
          p_idempotency_key: string;
          p_office_id: string;
          p_role_key: Database["public"]["Enums"]["role_key"];
          p_session_id: string;
          p_tenant_id: string;
          p_token_digest: string;
        };
        Returns: string;
      };
      create_membership: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_office_id: string;
          p_role_key: Database["public"]["Enums"]["role_key"];
          p_session_id: string;
          p_target_user_id: string;
          p_tenant_id: string;
        };
        Returns: string;
      };
      delivery_retry_delay_seconds: {
        Args: { p_attempt_number: number };
        Returns: number;
      };
      end_membership: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_membership_id: string;
          p_replacement_primary_membership_id?: string;
          p_session_id: string;
        };
        Returns: string;
      };
      enqueue_payout_verification: {
        Args: { p_stage_id: string };
        Returns: undefined;
      };
      ensure_wallet_for_member: {
        Args: { p_user_id: string };
        Returns: string;
      };
      expire_invitations: { Args: { p_at?: string }; Returns: number };
      fail_outbox_delivery: {
        Args: {
          p_error_code: string;
          p_latency_ms?: number;
          p_lease_token: string;
          p_now?: string;
          p_outbox_event_id: string;
          p_provider: string;
          p_provider_reference?: string;
          p_provider_status_code?: number;
          p_retryable: boolean;
        };
        Returns: Database["internal"]["Enums"]["integration_delivery_status"];
      };
      lock_active_office: {
        Args: { p_office_id: string; p_tenant_id: string };
        Returns: undefined;
      };
      lock_membership_subject: {
        Args: { p_tenant_id: string; p_user_id: string };
        Returns: undefined;
      };
      move_membership: {
        Args: {
          p_actor_user_id: string;
          p_destination_office_id: string;
          p_destination_role_key: Database["public"]["Enums"]["role_key"];
          p_idempotency_key: string;
          p_membership_id: string;
          p_session_id: string;
        };
        Returns: string;
      };
      organization_replay_result: {
        Args: {
          p_actor_user_id: string;
          p_command_type: string;
          p_idempotency_key: string;
          p_request_fingerprint: string;
          p_result_type: string;
        };
        Returns: string;
      };
      organization_request_fingerprint: {
        Args: { p_command_type: string; p_payload: Json };
        Returns: string;
      };
      payout_verification_replay: {
        Args: {
          p_fingerprint: string;
          p_job: string;
          p_revision: string;
          p_token: string;
          p_worker: string;
        };
        Returns: Json;
      };
      record_organization_command: {
        Args: {
          p_actor_user_id: string;
          p_command_type: string;
          p_idempotency_key: string;
          p_request_fingerprint: string;
          p_result_id: string;
          p_result_type: string;
          p_tenant_id: string;
        };
        Returns: undefined;
      };
      requeue_dead_letter_delivery: {
        Args: {
          p_now?: string;
          p_operator_reference: string;
          p_outbox_event_id: string;
          p_reason_code: string;
        };
        Returns: number;
      };
      revoke_invitation: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_invitation_id: string;
          p_session_id: string;
        };
        Returns: string;
      };
      suspend_membership: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_membership_id: string;
          p_session_id: string;
        };
        Returns: string;
      };
      validate_payout_verification_result: {
        Args: {
          p_facts: Json;
          p_job:
            Database["internal"]["Tables"]["payout_verification_jobs"]["Row"];
          p_reasons: Json;
        };
        Returns: undefined;
      };
    };
    Enums: {
      integration_attempt_outcome:
        | "delivered"
        | "retryable_failure"
        | "permanent_failure"
        | "lease_expired";
      integration_delivery_status:
        | "pending"
        | "processing"
        | "retry_scheduled"
        | "delivered"
        | "dead_lettered";
    };
    CompositeTypes: {
      outbox_delivery_claim: {
        outbox_event_id: string | null;
        tenant_id: string | null;
        aggregate_type: string | null;
        aggregate_id: string | null;
        event_type: string | null;
        payload: Json | null;
        occurred_at: string | null;
        delivery_cycle: number | null;
        attempt_number: number | null;
        lease_token: string | null;
        lease_expires_at: string | null;
        idempotency_key: string | null;
      };
    };
  };
  ledger: {
    Tables: {
      currency_definitions: {
        Row: {
          created_at: string;
          currency_code: string;
          minor_unit_scale: number;
        };
        Insert: {
          created_at?: string;
          currency_code: string;
          minor_unit_scale: number;
        };
        Update: {
          created_at?: string;
          currency_code?: string;
          minor_unit_scale?: number;
        };
        Relationships: [];
      };
      financial_transactions: {
        Row: {
          actor_user_id: string;
          created_at: string;
          id: string;
          idempotency_key: string;
          membership_id: string;
          metadata: Json;
          office_id: string;
          owner_user_id: string;
          posted_at: string | null;
          request_fingerprint: string;
          tenant_id: string;
          transaction_reference: string;
          transaction_type: string;
          wallet_id: string;
        };
        Insert: {
          actor_user_id: string;
          created_at?: string;
          id?: string;
          idempotency_key: string;
          membership_id: string;
          metadata?: Json;
          office_id: string;
          owner_user_id: string;
          posted_at?: string | null;
          request_fingerprint: string;
          tenant_id: string;
          transaction_reference?: string;
          transaction_type: string;
          wallet_id: string;
        };
        Update: {
          actor_user_id?: string;
          created_at?: string;
          id?: string;
          idempotency_key?: string;
          membership_id?: string;
          metadata?: Json;
          office_id?: string;
          owner_user_id?: string;
          posted_at?: string | null;
          request_fingerprint?: string;
          tenant_id?: string;
          transaction_reference?: string;
          transaction_type?: string;
          wallet_id?: string;
        };
        Relationships: [];
      };
      journal_entries: {
        Row: {
          created_at: string;
          currency_code: string;
          entry_number: number;
          financial_transaction_id: string;
          id: string;
        };
        Insert: {
          created_at?: string;
          currency_code: string;
          entry_number: number;
          financial_transaction_id: string;
          id?: string;
        };
        Update: {
          created_at?: string;
          currency_code?: string;
          entry_number?: number;
          financial_transaction_id?: string;
          id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "journal_entries_currency_code_fkey";
            columns: ["currency_code"];
            isOneToOne: false;
            referencedRelation: "currency_definitions";
            referencedColumns: ["currency_code"];
          },
          {
            foreignKeyName: "journal_entries_financial_transaction_id_fkey";
            columns: ["financial_transaction_id"];
            isOneToOne: false;
            referencedRelation: "financial_transactions";
            referencedColumns: ["id"];
          },
        ];
      };
      journal_postings: {
        Row: {
          amount: number;
          created_at: string;
          id: number;
          journal_entry_id: string;
          ledger_account_id: string;
          line_number: number;
        };
        Insert: {
          amount: number;
          created_at?: string;
          id?: never;
          journal_entry_id: string;
          ledger_account_id: string;
          line_number: number;
        };
        Update: {
          amount?: number;
          created_at?: string;
          id?: never;
          journal_entry_id?: string;
          ledger_account_id?: string;
          line_number?: number;
        };
        Relationships: [
          {
            foreignKeyName: "journal_postings_journal_entry_id_fkey";
            columns: ["journal_entry_id"];
            isOneToOne: false;
            referencedRelation: "journal_entries";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "journal_postings_ledger_account_id_fkey";
            columns: ["ledger_account_id"];
            isOneToOne: false;
            referencedRelation: "ledger_accounts";
            referencedColumns: ["id"];
          },
        ];
      };
      ledger_accounts: {
        Row: {
          account_class: Database["ledger"]["Enums"]["account_class"];
          created_at: string;
          currency_code: string;
          id: string;
          membership_id: string | null;
          office_id: string | null;
          owner_user_id: string | null;
          pocket_key: string | null;
          system_account_key: string | null;
          tenant_id: string | null;
          wallet_id: string | null;
        };
        Insert: {
          account_class: Database["ledger"]["Enums"]["account_class"];
          created_at?: string;
          currency_code: string;
          id?: string;
          membership_id?: string | null;
          office_id?: string | null;
          owner_user_id?: string | null;
          pocket_key?: string | null;
          system_account_key?: string | null;
          tenant_id?: string | null;
          wallet_id?: string | null;
        };
        Update: {
          account_class?: Database["ledger"]["Enums"]["account_class"];
          created_at?: string;
          currency_code?: string;
          id?: string;
          membership_id?: string | null;
          office_id?: string | null;
          owner_user_id?: string | null;
          pocket_key?: string | null;
          system_account_key?: string | null;
          tenant_id?: string | null;
          wallet_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "ledger_accounts_currency_code_fkey";
            columns: ["currency_code"];
            isOneToOne: false;
            referencedRelation: "currency_definitions";
            referencedColumns: ["currency_code"];
          },
        ];
      };
      wallet_balance_projections: {
        Row: {
          balance: number;
          last_posting_id: number;
          ledger_account_id: string;
          updated_at: string;
          version: number;
        };
        Insert: {
          balance?: number;
          last_posting_id: number;
          ledger_account_id: string;
          updated_at?: string;
          version?: number;
        };
        Update: {
          balance?: number;
          last_posting_id?: number;
          ledger_account_id?: string;
          updated_at?: string;
          version?: number;
        };
        Relationships: [
          {
            foreignKeyName: "wallet_balance_projections_last_posting_id_fkey";
            columns: ["last_posting_id"];
            isOneToOne: false;
            referencedRelation: "journal_postings";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "wallet_balance_projections_ledger_account_id_fkey";
            columns: ["ledger_account_id"];
            isOneToOne: true;
            referencedRelation: "ledger_accounts";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      generate_transaction_reference: { Args: never; Returns: string };
      post_transaction: {
        Args: {
          p_actor_user_id: string;
          p_idempotency_key: string;
          p_journals: Json;
          p_membership_id: string;
          p_metadata?: Json;
          p_request_fingerprint: string;
          p_transaction_type: string;
          p_wallet_id: string;
        };
        Returns:
          Database["ledger"]["CompositeTypes"]["post_transaction_result"];
        SetofOptions: {
          from: "*";
          to: "post_transaction_result";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
    };
    Enums: {
      account_class: "member_value" | "system_counter";
    };
    CompositeTypes: {
      post_transaction_result: {
        transaction_id: string | null;
        transaction_reference: string | null;
        reused: boolean | null;
      };
    };
  };
  public: {
    Tables: {
      allocation_policy_rules: {
        Row: {
          allocation_basis_points: number;
          pocket_key: string;
          policy_version_id: string;
          remainder_rank: number;
          tenant_id: string;
        };
        Insert: {
          allocation_basis_points: number;
          pocket_key: string;
          policy_version_id: string;
          remainder_rank: number;
          tenant_id: string;
        };
        Update: {
          allocation_basis_points?: number;
          pocket_key?: string;
          policy_version_id?: string;
          remainder_rank?: number;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "allocation_policy_rules_pocket_key_fkey";
            columns: ["pocket_key"];
            isOneToOne: false;
            referencedRelation: "pocket_definitions";
            referencedColumns: ["pocket_key"];
          },
          {
            foreignKeyName:
              "allocation_policy_rules_tenant_id_policy_version_id_fkey";
            columns: ["tenant_id", "policy_version_id"];
            isOneToOne: false;
            referencedRelation: "allocation_policy_versions";
            referencedColumns: ["tenant_id", "id"];
          },
        ];
      };
      allocation_policy_versions: {
        Row: {
          activated_at: string | null;
          created_at: string;
          created_by_user_id: string;
          id: string;
          tenant_id: string;
          version_number: number;
        };
        Insert: {
          activated_at?: string | null;
          created_at?: string;
          created_by_user_id: string;
          id?: string;
          tenant_id: string;
          version_number: number;
        };
        Update: {
          activated_at?: string | null;
          created_at?: string;
          created_by_user_id?: string;
          id?: string;
          tenant_id?: string;
          version_number?: number;
        };
        Relationships: [
          {
            foreignKeyName:
              "allocation_policy_versions_created_by_user_id_fkey";
            columns: ["created_by_user_id"];
            isOneToOne: false;
            referencedRelation: "user_accounts";
            referencedColumns: ["user_id"];
          },
          {
            foreignKeyName: "allocation_policy_versions_tenant_id_fkey";
            columns: ["tenant_id"];
            isOneToOne: false;
            referencedRelation: "tenants";
            referencedColumns: ["id"];
          },
        ];
      };
      invitations: {
        Row: {
          accepted_membership_id: string | null;
          accepted_user_id: string | null;
          created_at: string;
          email: string;
          expires_at: string;
          id: string;
          office_id: string | null;
          role_key: Database["public"]["Enums"]["role_key"];
          status: Database["public"]["Enums"]["invitation_status"];
          tenant_id: string;
          token_digest: string;
          updated_at: string;
        };
        Insert: {
          accepted_membership_id?: string | null;
          accepted_user_id?: string | null;
          created_at?: string;
          email: string;
          expires_at: string;
          id?: string;
          office_id?: string | null;
          role_key: Database["public"]["Enums"]["role_key"];
          status?: Database["public"]["Enums"]["invitation_status"];
          tenant_id: string;
          token_digest: string;
          updated_at?: string;
        };
        Update: {
          accepted_membership_id?: string | null;
          accepted_user_id?: string | null;
          created_at?: string;
          email?: string;
          expires_at?: string;
          id?: string;
          office_id?: string | null;
          role_key?: Database["public"]["Enums"]["role_key"];
          status?: Database["public"]["Enums"]["invitation_status"];
          tenant_id?: string;
          token_digest?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "invitations_accepted_user_id_fkey";
            columns: ["accepted_user_id"];
            isOneToOne: false;
            referencedRelation: "user_accounts";
            referencedColumns: ["user_id"];
          },
          {
            foreignKeyName: "invitations_tenant_id_accepted_membership_id_fkey";
            columns: ["tenant_id", "accepted_membership_id"];
            isOneToOne: false;
            referencedRelation: "memberships";
            referencedColumns: ["tenant_id", "id"];
          },
          {
            foreignKeyName: "invitations_tenant_id_fkey";
            columns: ["tenant_id"];
            isOneToOne: false;
            referencedRelation: "tenants";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "invitations_tenant_id_office_id_fkey";
            columns: ["tenant_id", "office_id"];
            isOneToOne: false;
            referencedRelation: "offices";
            referencedColumns: ["tenant_id", "id"];
          },
        ];
      };
      memberships: {
        Row: {
          created_at: string;
          ended_at: string | null;
          id: string;
          is_primary: boolean;
          office_id: string | null;
          role_key: Database["public"]["Enums"]["role_key"];
          starts_at: string;
          status: Database["public"]["Enums"]["membership_status"];
          tenant_id: string;
          updated_at: string;
          user_id: string;
        };
        Insert: {
          created_at?: string;
          ended_at?: string | null;
          id?: string;
          is_primary?: boolean;
          office_id?: string | null;
          role_key: Database["public"]["Enums"]["role_key"];
          starts_at?: string;
          status?: Database["public"]["Enums"]["membership_status"];
          tenant_id: string;
          updated_at?: string;
          user_id: string;
        };
        Update: {
          created_at?: string;
          ended_at?: string | null;
          id?: string;
          is_primary?: boolean;
          office_id?: string | null;
          role_key?: Database["public"]["Enums"]["role_key"];
          starts_at?: string;
          status?: Database["public"]["Enums"]["membership_status"];
          tenant_id?: string;
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "memberships_tenant_id_fkey";
            columns: ["tenant_id"];
            isOneToOne: false;
            referencedRelation: "tenants";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "memberships_tenant_id_office_id_fkey";
            columns: ["tenant_id", "office_id"];
            isOneToOne: false;
            referencedRelation: "offices";
            referencedColumns: ["tenant_id", "id"];
          },
          {
            foreignKeyName: "memberships_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "user_accounts";
            referencedColumns: ["user_id"];
          },
        ];
      };
      offices: {
        Row: {
          created_at: string;
          id: string;
          name: string;
          office_type: Database["public"]["Enums"]["office_type"];
          parent_office_id: string | null;
          status: Database["public"]["Enums"]["office_status"];
          tenant_id: string;
          updated_at: string;
        };
        Insert: {
          created_at?: string;
          id?: string;
          name: string;
          office_type: Database["public"]["Enums"]["office_type"];
          parent_office_id?: string | null;
          status?: Database["public"]["Enums"]["office_status"];
          tenant_id: string;
          updated_at?: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          name?: string;
          office_type?: Database["public"]["Enums"]["office_type"];
          parent_office_id?: string | null;
          status?: Database["public"]["Enums"]["office_status"];
          tenant_id?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "offices_tenant_id_fkey";
            columns: ["tenant_id"];
            isOneToOne: false;
            referencedRelation: "tenants";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "offices_tenant_id_parent_office_id_fkey";
            columns: ["tenant_id", "parent_office_id"];
            isOneToOne: false;
            referencedRelation: "offices";
            referencedColumns: ["tenant_id", "id"];
          },
        ];
      };
      pocket_definitions: {
        Row: {
          allows_negative: boolean;
          created_at: string;
          display_name: string;
          pocket_key: string;
          sort_order: number;
          transfer_in_allowed: boolean;
          transfer_out_allowed: boolean;
        };
        Insert: {
          allows_negative?: boolean;
          created_at?: string;
          display_name: string;
          pocket_key: string;
          sort_order: number;
          transfer_in_allowed?: boolean;
          transfer_out_allowed?: boolean;
        };
        Update: {
          allows_negative?: boolean;
          created_at?: string;
          display_name?: string;
          pocket_key?: string;
          sort_order?: number;
          transfer_in_allowed?: boolean;
          transfer_out_allowed?: boolean;
        };
        Relationships: [];
      };
      tenant_active_allocation_policies: {
        Row: {
          activated_at: string;
          activated_by_user_id: string;
          policy_version_id: string;
          tenant_id: string;
        };
        Insert: {
          activated_at?: string;
          activated_by_user_id: string;
          policy_version_id: string;
          tenant_id: string;
        };
        Update: {
          activated_at?: string;
          activated_by_user_id?: string;
          policy_version_id?: string;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "tenant_active_allocation_polic_tenant_id_policy_version_id_fkey";
            columns: ["tenant_id", "policy_version_id"];
            isOneToOne: false;
            referencedRelation: "allocation_policy_versions";
            referencedColumns: ["tenant_id", "id"];
          },
          {
            foreignKeyName:
              "tenant_active_allocation_policies_activated_by_user_id_fkey";
            columns: ["activated_by_user_id"];
            isOneToOne: false;
            referencedRelation: "user_accounts";
            referencedColumns: ["user_id"];
          },
          {
            foreignKeyName: "tenant_active_allocation_policies_tenant_id_fkey";
            columns: ["tenant_id"];
            isOneToOne: true;
            referencedRelation: "tenants";
            referencedColumns: ["id"];
          },
        ];
      };
      tenant_member_branding_read: {
        Row: {
          dark_logo_asset_id: string | null;
          light_logo_asset_id: string | null;
          primary_logo_asset_id: string | null;
          refreshed_at: string;
          revision_id: string;
          revision_number: number;
          square_app_icon_asset_id: string | null;
          support_url: string | null;
          team_display_name: string;
          team_short_name: string | null;
          team_slogan: string | null;
          tenant_id: string;
          theme_key: string | null;
        };
        Insert: {
          dark_logo_asset_id?: string | null;
          light_logo_asset_id?: string | null;
          primary_logo_asset_id?: string | null;
          refreshed_at?: string;
          revision_id: string;
          revision_number: number;
          square_app_icon_asset_id?: string | null;
          support_url?: string | null;
          team_display_name: string;
          team_short_name?: string | null;
          team_slogan?: string | null;
          tenant_id: string;
          theme_key?: string | null;
        };
        Update: {
          dark_logo_asset_id?: string | null;
          light_logo_asset_id?: string | null;
          primary_logo_asset_id?: string | null;
          refreshed_at?: string;
          revision_id?: string;
          revision_number?: number;
          square_app_icon_asset_id?: string | null;
          support_url?: string | null;
          team_display_name?: string;
          team_short_name?: string | null;
          team_slogan?: string | null;
          tenant_id?: string;
          theme_key?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "tenant_member_branding_read_tenant_id_fkey";
            columns: ["tenant_id"];
            isOneToOne: true;
            referencedRelation: "tenants";
            referencedColumns: ["id"];
          },
        ];
      };
      tenants: {
        Row: {
          authz_version: number;
          created_at: string;
          id: string;
          name: string;
          status: Database["public"]["Enums"]["tenant_status"];
          updated_at: string;
        };
        Insert: {
          authz_version?: number;
          created_at?: string;
          id?: string;
          name: string;
          status?: Database["public"]["Enums"]["tenant_status"];
          updated_at?: string;
        };
        Update: {
          authz_version?: number;
          created_at?: string;
          id?: string;
          name?: string;
          status?: Database["public"]["Enums"]["tenant_status"];
          updated_at?: string;
        };
        Relationships: [];
      };
      user_accounts: {
        Row: {
          authz_version: number;
          created_at: string;
          public_uid: string;
          status: Database["public"]["Enums"]["account_status"];
          updated_at: string;
          user_id: string;
        };
        Insert: {
          authz_version?: number;
          created_at?: string;
          public_uid?: string;
          status?: Database["public"]["Enums"]["account_status"];
          updated_at?: string;
          user_id: string;
        };
        Update: {
          authz_version?: number;
          created_at?: string;
          public_uid?: string;
          status?: Database["public"]["Enums"]["account_status"];
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [];
      };
      user_profiles: {
        Row: {
          created_at: string;
          display_name: string | null;
          first_name: string | null;
          last_name: string | null;
          phone_e164: string | null;
          timezone: string | null;
          updated_at: string;
          user_id: string;
        };
        Insert: {
          created_at?: string;
          display_name?: string | null;
          first_name?: string | null;
          last_name?: string | null;
          phone_e164?: string | null;
          timezone?: string | null;
          updated_at?: string;
          user_id: string;
        };
        Update: {
          created_at?: string;
          display_name?: string | null;
          first_name?: string | null;
          last_name?: string | null;
          phone_e164?: string | null;
          timezone?: string | null;
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "user_profiles_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: true;
            referencedRelation: "user_accounts";
            referencedColumns: ["user_id"];
          },
        ];
      };
      wallets: {
        Row: {
          created_at: string;
          id: string;
          owner_user_id: string;
        };
        Insert: {
          created_at?: string;
          id?: string;
          owner_user_id: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          owner_user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "wallets_owner_user_id_fkey";
            columns: ["owner_user_id"];
            isOneToOne: true;
            referencedRelation: "user_accounts";
            referencedColumns: ["user_id"];
          },
        ];
      };
      workspace_requests: {
        Row: {
          created_at: string;
          decided_at: string | null;
          decided_by_user_id: string | null;
          decision_reason: string | null;
          entry_token_digest: string;
          id: string;
          office_id: string | null;
          requested_office_name: string;
          requester_email: string;
          requester_full_name: string;
          requester_phone: string;
          requester_rank: string;
          status: string;
          tenant_id: string;
          updated_at: string;
        };
        Insert: {
          created_at?: string;
          decided_at?: string | null;
          decided_by_user_id?: string | null;
          decision_reason?: string | null;
          entry_token_digest: string;
          id?: string;
          office_id?: string | null;
          requested_office_name: string;
          requester_email: string;
          requester_full_name: string;
          requester_phone: string;
          requester_rank: string;
          status?: string;
          tenant_id: string;
          updated_at?: string;
        };
        Update: {
          created_at?: string;
          decided_at?: string | null;
          decided_by_user_id?: string | null;
          decision_reason?: string | null;
          entry_token_digest?: string;
          id?: string;
          office_id?: string | null;
          requested_office_name?: string;
          requester_email?: string;
          requester_full_name?: string;
          requester_phone?: string;
          requester_rank?: string;
          status?: string;
          tenant_id?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "workspace_requests_decided_by_user_id_fkey";
            columns: ["decided_by_user_id"];
            isOneToOne: false;
            referencedRelation: "user_accounts";
            referencedColumns: ["user_id"];
          },
          {
            foreignKeyName: "workspace_requests_office_id_fkey";
            columns: ["office_id"];
            isOneToOne: false;
            referencedRelation: "offices";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "workspace_requests_tenant_id_fkey";
            columns: ["tenant_id"];
            isOneToOne: false;
            referencedRelation: "tenants";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      add_own_payout_account: {
        Args: {
          p_account_holder_name: string;
          p_account_reference: string;
          p_actor_user_id: string;
          p_country_code: string;
          p_idempotency_key: string;
          p_institution_code: string;
          p_institution_name: string;
          p_membership_id: string;
          p_payout_currency: string;
          p_payout_rail: string;
          p_session_id: string;
        };
        Returns: Json;
      };
      current_step_up: { Args: never; Returns: Json };
      establish_step_up: { Args: never; Returns: Json };
      generate_public_uid: { Args: never; Returns: string };
    };
    Enums: {
      account_status:
        | "active"
        | "suspended"
        | "disabled"
        | "restricted"
        | "deactivated";
      invitation_status: "pending" | "accepted" | "expired" | "revoked";
      membership_status: "active" | "suspended" | "ended";
      office_status: "active" | "closed";
      office_type: "world_team" | "director" | "team_leader";
      role_key:
        | "member"
        | "team_leader"
        | "director"
        | "world_team_member"
        | "president_team_member";
      tenant_status: "active" | "suspended" | "deactivated";
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
  tenant_config: {
    Tables: {
      active_configuration: {
        Row: {
          activated_at: string;
          revision_id: string;
          tenant_id: string;
        };
        Insert: {
          activated_at?: string;
          revision_id: string;
          tenant_id: string;
        };
        Update: {
          activated_at?: string;
          revision_id?: string;
          tenant_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "active_configuration_tenant_id_revision_id_fkey";
            columns: ["tenant_id", "revision_id"];
            isOneToOne: false;
            referencedRelation: "configuration_revisions";
            referencedColumns: ["tenant_id", "id"];
          },
        ];
      };
      brand_asset_upload_intents: {
        Row: {
          asset_kind: string;
          created_at: string;
          expires_at: string;
          file_size_bytes: number;
          finalized_asset_id: string | null;
          finalized_at: string | null;
          height_pixels: number | null;
          id: string;
          idempotency_key: string;
          mime_type: string;
          sha256: string;
          status: Database["evidence"]["Enums"]["upload_intent_status"];
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_by_user_id: string;
          tenant_id: string;
          width_pixels: number | null;
        };
        Insert: {
          asset_kind: string;
          created_at?: string;
          expires_at: string;
          file_size_bytes: number;
          finalized_asset_id?: string | null;
          finalized_at?: string | null;
          height_pixels?: number | null;
          id?: string;
          idempotency_key: string;
          mime_type: string;
          sha256: string;
          status?: Database["evidence"]["Enums"]["upload_intent_status"];
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_by_user_id: string;
          tenant_id: string;
          width_pixels?: number | null;
        };
        Update: {
          asset_kind?: string;
          created_at?: string;
          expires_at?: string;
          file_size_bytes?: number;
          finalized_asset_id?: string | null;
          finalized_at?: string | null;
          height_pixels?: number | null;
          id?: string;
          idempotency_key?: string;
          mime_type?: string;
          sha256?: string;
          status?: Database["evidence"]["Enums"]["upload_intent_status"];
          storage_bucket_id?: string;
          storage_object_path?: string;
          submitted_by_user_id?: string;
          tenant_id?: string;
          width_pixels?: number | null;
        };
        Relationships: [
          {
            foreignKeyName:
              "brand_asset_upload_intents_finalized_asset_id_fkey";
            columns: ["finalized_asset_id"];
            isOneToOne: false;
            referencedRelation: "brand_assets";
            referencedColumns: ["id"];
          },
        ];
      };
      brand_assets: {
        Row: {
          asset_kind: string;
          byte_size: number;
          checksum_sha256: string;
          created_at: string;
          created_by_user_id: string;
          height_pixels: number | null;
          id: string;
          mime_type: string;
          status: Database["tenant_config"]["Enums"]["asset_status"];
          storage_object_path: string;
          tenant_id: string;
          width_pixels: number | null;
        };
        Insert: {
          asset_kind: string;
          byte_size: number;
          checksum_sha256: string;
          created_at?: string;
          created_by_user_id: string;
          height_pixels?: number | null;
          id?: string;
          mime_type: string;
          status?: Database["tenant_config"]["Enums"]["asset_status"];
          storage_object_path: string;
          tenant_id: string;
          width_pixels?: number | null;
        };
        Update: {
          asset_kind?: string;
          byte_size?: number;
          checksum_sha256?: string;
          created_at?: string;
          created_by_user_id?: string;
          height_pixels?: number | null;
          id?: string;
          mime_type?: string;
          status?: Database["tenant_config"]["Enums"]["asset_status"];
          storage_object_path?: string;
          tenant_id?: string;
          width_pixels?: number | null;
        };
        Relationships: [];
      };
      command_idempotency: {
        Row: {
          actor_user_id: string;
          command_type: string;
          created_at: string;
          idempotency_key: string;
          request_fingerprint: string;
          result_id: string;
          tenant_id: string;
        };
        Insert: {
          actor_user_id: string;
          command_type: string;
          created_at?: string;
          idempotency_key: string;
          request_fingerprint: string;
          result_id: string;
          tenant_id: string;
        };
        Update: {
          actor_user_id?: string;
          command_type?: string;
          created_at?: string;
          idempotency_key?: string;
          request_fingerprint?: string;
          result_id?: string;
          tenant_id?: string;
        };
        Relationships: [];
      };
      configuration_revisions: {
        Row: {
          created_at: string;
          created_by_user_id: string;
          dark_logo_asset_id: string | null;
          id: string;
          light_logo_asset_id: string | null;
          locale_code: string;
          primary_logo_asset_id: string | null;
          revision_number: number;
          revision_reason: string;
          square_app_icon_asset_id: string | null;
          support_contact_email: string | null;
          support_contact_name: string | null;
          support_contact_phone: string | null;
          support_url: string | null;
          team_display_name: string;
          team_short_name: string | null;
          team_slogan: string | null;
          tenant_id: string;
          theme_key: string | null;
          timezone_name: string;
        };
        Insert: {
          created_at?: string;
          created_by_user_id: string;
          dark_logo_asset_id?: string | null;
          id?: string;
          light_logo_asset_id?: string | null;
          locale_code: string;
          primary_logo_asset_id?: string | null;
          revision_number: number;
          revision_reason: string;
          square_app_icon_asset_id?: string | null;
          support_contact_email?: string | null;
          support_contact_name?: string | null;
          support_contact_phone?: string | null;
          support_url?: string | null;
          team_display_name: string;
          team_short_name?: string | null;
          team_slogan?: string | null;
          tenant_id: string;
          theme_key?: string | null;
          timezone_name: string;
        };
        Update: {
          created_at?: string;
          created_by_user_id?: string;
          dark_logo_asset_id?: string | null;
          id?: string;
          light_logo_asset_id?: string | null;
          locale_code?: string;
          primary_logo_asset_id?: string | null;
          revision_number?: number;
          revision_reason?: string;
          square_app_icon_asset_id?: string | null;
          support_contact_email?: string | null;
          support_contact_name?: string | null;
          support_contact_phone?: string | null;
          support_url?: string | null;
          team_display_name?: string;
          team_short_name?: string | null;
          team_slogan?: string | null;
          tenant_id?: string;
          theme_key?: string | null;
          timezone_name?: string;
        };
        Relationships: [
          {
            foreignKeyName:
              "configuration_revisions_tenant_id_dark_logo_asset_id_fkey";
            columns: ["tenant_id", "dark_logo_asset_id"];
            isOneToOne: false;
            referencedRelation: "brand_assets";
            referencedColumns: ["tenant_id", "id"];
          },
          {
            foreignKeyName:
              "configuration_revisions_tenant_id_light_logo_asset_id_fkey";
            columns: ["tenant_id", "light_logo_asset_id"];
            isOneToOne: false;
            referencedRelation: "brand_assets";
            referencedColumns: ["tenant_id", "id"];
          },
          {
            foreignKeyName:
              "configuration_revisions_tenant_id_primary_logo_asset_id_fkey";
            columns: ["tenant_id", "primary_logo_asset_id"];
            isOneToOne: false;
            referencedRelation: "brand_assets";
            referencedColumns: ["tenant_id", "id"];
          },
          {
            foreignKeyName:
              "configuration_revisions_tenant_id_square_app_icon_asset_id_fkey";
            columns: ["tenant_id", "square_app_icon_asset_id"];
            isOneToOne: false;
            referencedRelation: "brand_assets";
            referencedColumns: ["tenant_id", "id"];
          },
        ];
      };
      custom_domains: {
        Row: {
          activated_at: string | null;
          created_at: string;
          created_by_user_id: string;
          hostname: string;
          id: string;
          revoked_at: string | null;
          status: Database["tenant_config"]["Enums"]["custom_domain_status"];
          tenant_id: string;
          verification_token: string;
          verified_at: string | null;
        };
        Insert: {
          activated_at?: string | null;
          created_at?: string;
          created_by_user_id: string;
          hostname: string;
          id?: string;
          revoked_at?: string | null;
          status?: Database["tenant_config"]["Enums"]["custom_domain_status"];
          tenant_id: string;
          verification_token: string;
          verified_at?: string | null;
        };
        Update: {
          activated_at?: string | null;
          created_at?: string;
          created_by_user_id?: string;
          hostname?: string;
          id?: string;
          revoked_at?: string | null;
          status?: Database["tenant_config"]["Enums"]["custom_domain_status"];
          tenant_id?: string;
          verification_token?: string;
          verified_at?: string | null;
        };
        Relationships: [];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      finalize_brand_asset_upload: {
        Args: {
          p_actor_user_id: string;
          p_intent_id: string;
          p_session_id: string;
          p_verified_file_size_bytes: number;
          p_verified_sha256_hex: string;
        };
        Returns: {
          asset_kind: string;
          byte_size: number;
          checksum_sha256: string;
          created_at: string;
          created_by_user_id: string;
          height_pixels: number | null;
          id: string;
          mime_type: string;
          status: Database["tenant_config"]["Enums"]["asset_status"];
          storage_object_path: string;
          tenant_id: string;
          width_pixels: number | null;
        };
        SetofOptions: {
          from: "*";
          to: "brand_assets";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      register_brand_asset: {
        Args: {
          p_actor_user_id: string;
          p_asset_kind: string;
          p_byte_size: number;
          p_checksum_sha256: string;
          p_height_pixels: number;
          p_idempotency_key: string;
          p_mime_type: string;
          p_session_id: string;
          p_storage_object_path: string;
          p_tenant_id: string;
          p_width_pixels: number;
        };
        Returns: {
          asset_kind: string;
          byte_size: number;
          checksum_sha256: string;
          created_at: string;
          created_by_user_id: string;
          height_pixels: number | null;
          id: string;
          mime_type: string;
          status: Database["tenant_config"]["Enums"]["asset_status"];
          storage_object_path: string;
          tenant_id: string;
          width_pixels: number | null;
        };
        SetofOptions: {
          from: "*";
          to: "brand_assets";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      request_brand_asset_upload: {
        Args: {
          p_actor_user_id: string;
          p_asset_kind: string;
          p_file_size_bytes: number;
          p_height_pixels: number;
          p_idempotency_key: string;
          p_mime_type: string;
          p_session_id: string;
          p_sha256_hex: string;
          p_tenant_id: string;
          p_width_pixels: number;
        };
        Returns: {
          asset_kind: string;
          created_at: string;
          expires_at: string;
          file_size_bytes: number;
          finalized_asset_id: string | null;
          finalized_at: string | null;
          height_pixels: number | null;
          id: string;
          idempotency_key: string;
          mime_type: string;
          sha256: string;
          status: Database["evidence"]["Enums"]["upload_intent_status"];
          storage_bucket_id: string;
          storage_object_path: string;
          submitted_by_user_id: string;
          tenant_id: string;
          width_pixels: number | null;
        };
        SetofOptions: {
          from: "*";
          to: "brand_asset_upload_intents";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      request_fingerprint: {
        Args: { p_command_type: string; p_payload: Json };
        Returns: string;
      };
      update_team_configuration: {
        Args: {
          p_actor_user_id: string;
          p_dark_logo_asset_id: string;
          p_idempotency_key: string;
          p_light_logo_asset_id: string;
          p_locale_code: string;
          p_primary_logo_asset_id: string;
          p_revision_reason: string;
          p_session_id: string;
          p_square_app_icon_asset_id: string;
          p_support_contact_email: string;
          p_support_contact_name: string;
          p_support_contact_phone: string;
          p_support_url: string;
          p_team_display_name: string;
          p_team_short_name: string;
          p_team_slogan: string;
          p_tenant_id: string;
          p_theme_key: string;
          p_timezone_name: string;
        };
        Returns: {
          created_at: string;
          created_by_user_id: string;
          dark_logo_asset_id: string | null;
          id: string;
          light_logo_asset_id: string | null;
          locale_code: string;
          primary_logo_asset_id: string | null;
          revision_number: number;
          revision_reason: string;
          square_app_icon_asset_id: string | null;
          support_contact_email: string | null;
          support_contact_name: string | null;
          support_contact_phone: string | null;
          support_url: string | null;
          team_display_name: string;
          team_short_name: string | null;
          team_slogan: string | null;
          tenant_id: string;
          theme_key: string | null;
          timezone_name: string;
        };
        SetofOptions: {
          from: "*";
          to: "configuration_revisions";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
    };
    Enums: {
      asset_status: "active" | "retired";
      custom_domain_status:
        | "pending_verification"
        | "verified"
        | "active"
        | "revoked";
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">;

type DefaultSchema =
  DatabaseWithoutInternals[Extract<keyof Database, "public">];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  } ? keyof (
      & DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]][
        "Tables"
      ]
      & DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]][
        "Views"
      ]
    )
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
} ? (
    & DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]][
      "Tables"
    ]
    & DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]][
      "Views"
    ]
  )[TableName] extends {
    Row: infer R;
  } ? R
  : never
  : DefaultSchemaTableNameOrOptions extends keyof (
    & DefaultSchema["Tables"]
    & DefaultSchema["Views"]
  ) ? (
      & DefaultSchema["Tables"]
      & DefaultSchema["Views"]
    )[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R;
    } ? R
    : never
  : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  } ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]][
      "Tables"
    ]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
} ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]][
    "Tables"
  ][TableName] extends {
    Insert: infer I;
  } ? I
  : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I;
    } ? I
    : never
  : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  } ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]][
      "Tables"
    ]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
} ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]][
    "Tables"
  ][TableName] extends {
    Update: infer U;
  } ? U
  : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U;
    } ? U
    : never
  : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  } ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]][
      "Enums"
    ]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
} ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][
    EnumName
  ]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never;

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  } ? keyof DatabaseWithoutInternals[
      PublicCompositeTypeNameOrOptions["schema"]
    ]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
} ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]][
    "CompositeTypes"
  ][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends
    keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never;

export const Constants = {
  authz: {
    Enums: {
      access_effect: ["allow", "deny"],
      access_scope_type: ["tenant", "office_subtree", "member"],
      authorization_decision_state: ["ALLOW", "DENY", "STEP_UP_REQUIRED"],
      authorization_source: [
        "protected_baseline",
        "role_policy",
        "explicit_grant",
        "explicit_deny",
        "system_rule",
        "default_deny",
      ],
      required_auth_level: ["none", "elevated", "elevated_and_confirmed"],
    },
  },
  commercial: {
    Enums: {
      subscription_status: [
        "active",
        "payment_due",
        "grace_period",
        "past_due",
        "suspended",
        "cancelled",
      ],
    },
  },
  evidence: {
    Enums: {
      review_decision: ["clear", "reject"],
      upload_intent_status: ["pending", "finalized", "expired", "cancelled"],
      verification_outcome: ["match", "mismatch"],
    },
  },
  financial_ops: {
    Enums: {
      adjustment_direction: ["credit", "debit"],
      evidence_operation_resolution: ["automated_match", "manual_clear"],
      evidence_operation_status: [
        "submitted",
        "correction_required",
        "needs_review",
        "rejected",
        "posted",
      ],
      payout_account_status: ["active", "deactivated", "replaced"],
      payout_assertion_status: [
        "submitted",
        "correction_required",
        "needs_review",
        "rejected",
        "posted",
      ],
      payout_resolution: ["automated_match", "manual_clear"],
      payout_verification_status: ["pending", "verified", "rejected"],
      pocket_transfer_status: [
        "requested",
        "completed",
        "rejected",
        "cancelled",
      ],
      reservation_status: ["active", "consumed", "released"],
      withdrawal_status: [
        "requested",
        "approved",
        "completed",
        "cancelled",
        "rejected",
      ],
    },
  },
  internal: {
    Enums: {
      integration_attempt_outcome: [
        "delivered",
        "retryable_failure",
        "permanent_failure",
        "lease_expired",
      ],
      integration_delivery_status: [
        "pending",
        "processing",
        "retry_scheduled",
        "delivered",
        "dead_lettered",
      ],
    },
  },
  ledger: {
    Enums: {
      account_class: ["member_value", "system_counter"],
    },
  },
  public: {
    Enums: {
      account_status: [
        "active",
        "suspended",
        "disabled",
        "restricted",
        "deactivated",
      ],
      invitation_status: ["pending", "accepted", "expired", "revoked"],
      membership_status: ["active", "suspended", "ended"],
      office_status: ["active", "closed"],
      office_type: ["world_team", "director", "team_leader"],
      role_key: [
        "member",
        "team_leader",
        "director",
        "world_team_member",
        "president_team_member",
      ],
      tenant_status: ["active", "suspended", "deactivated"],
    },
  },
  tenant_config: {
    Enums: {
      asset_status: ["active", "retired"],
      custom_domain_status: [
        "pending_verification",
        "verified",
        "active",
        "revoked",
      ],
    },
  },
} as const;
