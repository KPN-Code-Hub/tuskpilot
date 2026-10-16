import { SignInPageBlueprint } from '@backstage/plugin-app-react';
import { TuskpilotLogo } from './TuskpilotLogo';

/** The default guest sign-in, centred and branded. */
export const TuskpilotSignInPage = SignInPageBlueprint.make({
  params: {
    loader: async () => {
      const { SignInPage } = await import('@backstage/core-components');
      return props => (
        <SignInPage
          {...props}
          providers={['guest']}
          align="center"
          titleComponent={<TuskpilotLogo height={34} />}
        />
      );
    },
  },
});
