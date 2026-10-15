import { createFrontendModule } from '@backstage/frontend-plugin-api';
import { tuskpilotTheme } from '../theme';
import { AppShell, RootRedirect } from './AppShell';
import { TuskpilotSignInPage } from './SignIn';
import { SidebarContent } from './Sidebar';

export const navModule = createFrontendModule({
  pluginId: 'app',
  extensions: [
    SidebarContent,
    AppShell,
    RootRedirect,
    TuskpilotSignInPage,
    tuskpilotTheme,
  ],
});
