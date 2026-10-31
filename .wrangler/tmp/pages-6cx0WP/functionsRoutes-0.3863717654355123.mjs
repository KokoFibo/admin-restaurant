import { onRequestPost as __api_forgot_ts_onRequestPost } from "C:\\Users\\kokon\\OneDrive\\Desktop\\admin-restaurant\\functions\\api\\forgot.ts"
import { onRequestPost as __api_translate_ts_onRequestPost } from "C:\\Users\\kokon\\OneDrive\\Desktop\\admin-restaurant\\functions\\api\\translate.ts"
import { onRequestDelete as __api_upload_ts_onRequestDelete } from "C:\\Users\\kokon\\OneDrive\\Desktop\\admin-restaurant\\functions\\api\\upload.ts"
import { onRequestPost as __api_upload_ts_onRequestPost } from "C:\\Users\\kokon\\OneDrive\\Desktop\\admin-restaurant\\functions\\api\\upload.ts"
import { onRequestPost as __api_users_ts_onRequestPost } from "C:\\Users\\kokon\\OneDrive\\Desktop\\admin-restaurant\\functions\\api\\users.ts"

export const routes = [
    {
      routePath: "/api/forgot",
      mountPath: "/api",
      method: "POST",
      middlewares: [],
      modules: [__api_forgot_ts_onRequestPost],
    },
  {
      routePath: "/api/translate",
      mountPath: "/api",
      method: "POST",
      middlewares: [],
      modules: [__api_translate_ts_onRequestPost],
    },
  {
      routePath: "/api/upload",
      mountPath: "/api",
      method: "DELETE",
      middlewares: [],
      modules: [__api_upload_ts_onRequestDelete],
    },
  {
      routePath: "/api/upload",
      mountPath: "/api",
      method: "POST",
      middlewares: [],
      modules: [__api_upload_ts_onRequestPost],
    },
  {
      routePath: "/api/users",
      mountPath: "/api",
      method: "POST",
      middlewares: [],
      modules: [__api_users_ts_onRequestPost],
    },
  ]